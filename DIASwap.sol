// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/* ──────── OpenZeppelin ──────── */
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/* ──────── Interfaces ──────── */
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);

    /* IERC20 标准事件 */
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface IRootDispatch {
    function getSubContractAddress(string memory _name) external view returns (address);
}

interface IMint {
    function swapToken(address from, address to, uint256 amount) external returns (uint256[] memory amounts);
}

/* ──────── Library ──────── */
library TokenUtils {
    /// @notice 对地址进行排序，保证 pair 唯一性
    function sortTokens(
        address tokenA,
        address tokenB
    ) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "Identical addresses");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "Zero address");
    }
}
//  /* ──────── Safe Math ──────── */
//  library SafeMath {
//     function mul(uint256 a, uint256 b) internal pure returns (uint256) {
//         if (a == 0) return 0;
//         uint256 c = a * b;
//         require(c / a == b, "MUL_ERROR");
//         return c;
//     }

//     function div(uint256 a, uint256 b) internal pure returns (uint256) {
//          require(b > 0, "DIV_ZERO");
//         return a / b;
//      }
// }
/* ──────────────────────────────── UniswapV2Pair ──────────────────────────────── */
contract UniswapV2Pair is ReentrancyGuard {

    // 新增白名单
    mapping(address => bool) public feeWhitelist;
    // 新增函数：设置白名单，仅限 factory 调用
    function setFeeWhitelist(address account, bool status) external onlyFactory {
        feeWhitelist[account] = status;
    }


    using SafeMath for uint256;
    /* ---- 公共只读变量（与 Uniswap V2 对齐） ---- */
    address public factory;
    address public router;
    address public treasury;
    address public autoForwarder;
    address public token0;
    address public token1;
    string public constant name = "Uniswap V2";
    string public constant symbol = "UNI-V2";
    uint8 public constant decimals = 6;
    /* 以 uint112 保存以兼容 Uniswap V2 getReserves 返回值 */
    uint112 private reserve0;
    uint112 private reserve1;
    uint32  private blockTimestampLast;       // --- patched: 记录最后一次更新时间戳 (<=2^32‑1)
    uint256 public lastSwapBlock;
    uint256 public totalSupply;                         // LP 总量
    mapping(address => uint256) public balanceOf;       // LP 余额
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);                  // --- patched
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to); // --- patched
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    ); // --- patched
    event Sync(uint112 reserve0, uint112 reserve1);     // --- patched (Uniswap 标准)
    // event ReservesUpdated(uint256 reserve0, uint256 reserve1);

    uint256 private constant MINIMUM_LIQUIDITY = 1_000;

    /* ---- 手续费记账 ---- */
    uint256 public constant FEE_NUMERATOR = 25;       // 0.25%
    uint256 public constant FEE_DENOMINATOR = 10_000;

    uint256 public accFee0PerShare;   // 1e12 精度
    uint256 public accFee1PerShare;
    uint256 public totalFee0;
    uint256 public totalFee1;

    mapping(address => uint256) public userFee0Debt;
    mapping(address => uint256) public userFee1Debt;

    /* ---- 构造 ---- */
    constructor() {factory = msg.sender;}

    /* ---- 初始化 ---- */
    function initialize(address _token0, address _token1) external onlyFactory {
        require(token0 == address(0) && token1 == address(0), "Already initialized");
        token0 = _token0;
        token1 = _token1;
    }
    /* ====================================================================== *
                                │  设置 treasury / router / autoForwarder │
     * ====================================================================== */
    function setRouter(address _router) external onlyFactory {
        require(_router != address(0), "invalid address");
        router = _router;
    }

    function setTreasury(address _treasury) external onlyFactory {
        require(_treasury != address(0), "invalid address");
        treasury = _treasury;
    }

    function setAutoForwarder(address _autoForwarder) external onlyFactory {
        require(_autoForwarder != address(0), "invalid address");
        autoForwarder = _autoForwarder;
    }

    /* ====================================================================== *
                                │  LP 铸造 / 销毁 │
     * ====================================================================== */
    function mint(address to) external onlyAuthorized nonReentrant returns (uint256 liquidity) {
        // 防止价格操纵：不能在 swap 后的同一个区块内进行 mint
        require(block.number > lastSwapBlock || to == treasury || to == autoForwarder, "No mint in same block as swap");
        uint256 _reserve0 = reserve0;
        uint256 _reserve1 = reserve1;
        uint256 balance0 = IERC20(token0).balanceOf(address(this)) - totalFee0;
        uint256 balance1 = IERC20(token1).balanceOf(address(this)) - totalFee1;
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        if (totalSupply == 0) {
            uint256 product;
            unchecked {product = amount0 * amount1;}   // ← 不检查乘法
            liquidity = sqrt(product);
            require(liquidity > MINIMUM_LIQUIDITY, "Insufficient liquidity");
            unchecked {liquidity -= MINIMUM_LIQUIDITY;} // ← 不检查下溢
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            liquidity = min(
                (amount0.mul(totalSupply)).div(_reserve0),
                (amount1.mul(totalSupply)).div(_reserve1)
            );
            require(liquidity > 0, "Insufficient liquidity");
        }
        if (balanceOf[to] > 0) {
            _updateFee(to); // 结算旧的
        }
        _mint(to, liquidity);
        userFee0Debt[to] = (balanceOf[to].mul(accFee0PerShare)).div(1e12);
        userFee1Debt[to] = (balanceOf[to].mul(accFee1PerShare)).div(1e12);

        balance0 = IERC20(token0).balanceOf(address(this)) - totalFee0;
        balance1 = IERC20(token1).balanceOf(address(this)) - totalFee1;
        _update(balance0, balance1);

        emit Mint(msg.sender, amount0, amount1);    // --- patched
        // emit ReservesUpdated(reserve0, reserve1);
    }

    function burn(address to, uint256 liquidity) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(liquidity > 0, "Cannot burn zero");
        require(balanceOf[msg.sender] >= liquidity, "Insufficient LP balance");
        _updateFee(msg.sender);

        //uint256 liquidity    = balanceOf[msg.sender];
        uint256 _totalSupply = totalSupply;
        amount0 = (liquidity.mul(reserve0)).div(_totalSupply);
        amount1 = (liquidity.mul(reserve1)).div(_totalSupply);
        require(amount0 > 0 && amount1 > 0, "Insufficient liquidity");

        _burn(msg.sender, liquidity);

        _safeTransfer(token0, to, amount0);
        _safeTransfer(token1, to, amount1);

        _update(IERC20(token0).balanceOf(address(this)) - totalFee0, IERC20(token1).balanceOf(address(this)) - totalFee1);

        userFee0Debt[msg.sender] = (balanceOf[msg.sender].mul(accFee0PerShare)).div(1e12);
        userFee1Debt[msg.sender] = (balanceOf[msg.sender].mul(accFee1PerShare)).div(1e12);
        emit Burn(msg.sender, amount0, amount1, to);   // --- patched
        // emit ReservesUpdated(reserve0, reserve1);
    }

    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to
    ) external onlyAuthorized nonReentrant {
        require(amount0Out > 0 || amount1Out > 0, "Invalid output");
        require(amount0Out < reserve0 && amount1Out < reserve1, "Insufficient liquidity");

        if (amount0Out > 0) _safeTransfer(token0, to, amount0Out);
        if (amount1Out > 0) _safeTransfer(token1, to, amount1Out);

        uint256 balance0 = IERC20(token0).balanceOf(address(this)) - totalFee0;
        uint256 balance1 = IERC20(token1).balanceOf(address(this)) - totalFee1;

        uint256 amount0In = balance0 > reserve0 - amount0Out ? balance0 - (reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > reserve1 - amount1Out ? balance1 - (reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "Insufficient input amount");
        uint256 fee0 = 0;
        uint256 fee1 = 0;

        // 修改 swap 函数内手续费逻辑 包含白名单 pass：
        if (amount0In > 0 && to != treasury && !feeWhitelist[to]) { // 加入白名单判断
            fee0 = (amount0In.mul(FEE_NUMERATOR)).div(FEE_DENOMINATOR);
            totalFee0 += fee0;
            if (totalSupply > 0) accFee0PerShare += fee0.mul(1e12).div(totalSupply);
        }
        if (amount1In > 0 && to != treasury && !feeWhitelist[to]) { // 加入白名单判断
            fee1 = (amount1In.mul(FEE_NUMERATOR)).div(FEE_DENOMINATOR);
            totalFee1 += fee1;
            if (totalSupply > 0) accFee1PerShare += fee1.mul(1e12).div(totalSupply);
        }

        // 旧的手续费逻辑
        // if (amount0In > 0 && to != treasury) {
        //     fee0 = (amount0In.mul(FEE_NUMERATOR)).div(FEE_DENOMINATOR);
        //     if (totalSupply > 0) accFee0PerShare += fee0.mul(1e12).div(totalSupply);
        // }
        // if (amount1In > 0 && to != treasury) {
        //     fee1 = (amount1In .mul(FEE_NUMERATOR)).div(FEE_DENOMINATOR);
        //     if (totalSupply > 0) accFee1PerShare += fee1.mul(1e12).div(totalSupply);
        // }

        // 修改调整余额计算逻辑
        uint256 balance0Adj = balance0 .mul(FEE_DENOMINATOR) - fee0.mul(FEE_DENOMINATOR - FEE_NUMERATOR);
        uint256 balance1Adj = balance1 .mul(FEE_DENOMINATOR) - fee1.mul(FEE_DENOMINATOR - FEE_NUMERATOR);

        // require(
        //     balance0Adj * balance1Adj >= uint256(reserve0) * uint256(reserve1) * (FEE_DENOMINATOR ** 2),
        //     "K invariant"
        // );
        // 计算右侧时显式处理精度

        require(
            balance0Adj.mul(balance1Adj) >= uint256(reserve0)
            .mul(reserve1)
            .mul(FEE_DENOMINATOR)
            .mul(FEE_DENOMINATOR), // FEE_DENOMINATOR^2
            "K invariant"
        );


        _update(balance0 - fee0, balance1 - fee1);
        lastSwapBlock = block.number; // 记录 swap 的 block number
        emit Swap(
            msg.sender,
            amount0In,
            amount1In,
            amount0Out,
            amount1Out,
            to
        ); // --- patched
        // emit ReservesUpdated(reserve0, reserve1);
    }

    /* ---- 兼容 Uniswap V2 的辅助函数 ---- */
    function skim(address to) external nonReentrant onlyAuthorized { // --- patched
        _safeTransfer(token0, to, IERC20(token0).balanceOf(address(this)) - reserve0);
        _safeTransfer(token1, to, IERC20(token1).balanceOf(address(this)) - reserve1);
    }

    function sync() external nonReentrant onlyAuthorized { // --- patched
        _update(
            IERC20(token0).balanceOf(address(this)) - totalFee0,
            IERC20(token1).balanceOf(address(this)) - totalFee1
        );
        // emit ReservesUpdated(reserve0, reserve1);
    }

    /* ---- 手续费结算 ---- */
    function _updateFee(address user) internal {
        uint256 liqu = balanceOf[user];
        if (liqu == 0 || totalSupply == 0) return;

        // 计算当前应得费用
        uint256 currentFee0 = liqu.mul(accFee0PerShare).div(1e12);
        uint256 currentFee1 = liqu.mul(accFee1PerShare).div(1e12);

        // 处理负值（若应得费用 < 历史债务，则 pending = 0）
        uint256 pending0 = currentFee0 > userFee0Debt[user] ? currentFee0 - userFee0Debt[user] : 0;
        uint256 pending1 = currentFee1 > userFee1Debt[user] ? currentFee1 - userFee1Debt[user] : 0;

        if (pending0 > 0) {
            _safeTransfer(token0, user, pending0);
            totalFee0 -= pending0;
        }
        if (pending1 > 0) {
            _safeTransfer(token1, user, pending1);
            totalFee1 -= pending1;
        }

        userFee0Debt[user] = (liqu.mul(accFee0PerShare)).div(1e12);
        userFee1Debt[user] = (liqu.mul(accFee1PerShare)).div(1e12);
    }

    /* ---- View ---- */
    /// @notice 与 Uniswap V2 相同签名，多返回一个时间戳，旧调用只取前两项可向后兼容
    function getReserves() external view returns (uint112, uint112, uint32) { // --- patched
        return (reserve0, reserve1, blockTimestampLast);
    }

    /* ---- ERC‑20 Lite ---- */
    function transfer(address to, uint256 value) external nonReentrant returns (bool) {
        require(balanceOf[msg.sender] >= value, "Insufficient balance");
        _updateFee(msg.sender);
        _updateFee(to);
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;

        emit Transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external nonReentrant returns (bool) {
        require(balanceOf[from] >= value, "Insufficient balance");
        require(allowance[from][msg.sender] >= value, "Allowance exceeded");

        _updateFee(from);
        _updateFee(to);
        balanceOf[from] -= value;
        balanceOf[to] += value;
        allowance[from][msg.sender] -= value;

        emit Transfer(from, to, value);
        return true;
    }

    /* ---- 内部工具 ---- */
    function _update(uint256 bal0, uint256 bal1) private {
        reserve0 = uint112(bal0);
        reserve1 = uint112(bal1);
        blockTimestampLast = uint32(block.timestamp % 2 ** 32); // --- patched
        emit Sync(reserve0, reserve1);                        // --- patched
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        require(token != address(0), "Zero token"); // --- patched
        require(token.code.length > 0, "Not contract");
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "Transfer failed");
    }

    /* ---- 数学工具 ---- */
    function sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = (y >> 1) + 1;
            while (x < z) {z = x;
                x = (y / x + x) >> 1;}
        } else if (y != 0) {z = 1;}
    }

    function min(uint256 a, uint256 b) private pure returns (uint256) {return a < b ? a : b;}

    /* ---- ERC‑20 内部 _mint / _burn ---- */
    function _mint(address to, uint256 value) private {
        balanceOf[to] += value;
        totalSupply += value;
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint256 value) private {
        balanceOf[from] -= value;
        totalSupply -= value;
        emit Transfer(from, address(0), value);
    }

    /* ---- 修饰符 ---- */
    modifier onlyFactory()    {require(msg.sender == factory, "Only Factory");
        _;}
    modifier onlyAuthorized() {require(msg.sender == factory || msg.sender == router, "Unauthorized");
        _;}
}

/* ──────────────────────────────── UniswapV2Factory ──────────────────────────────── */
contract UniswapV2Factory {

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;
    address public manager;
    address public owner;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);
    event RouterSet(address indexed pair, address router);
    event FeeWhitelistUpdated(address indexed pair, address account, bool status);

    constructor(address _owner) {
        owner = _owner;
        manager = msg.sender;
    }

    // 在Factory中设置白名单，限 Manager 调用
    function setPairFeeWhitelist(address _pair, address _account, bool _status) external onlyManager {
        UniswapV2Pair(_pair).setFeeWhitelist(_account, _status);
        emit FeeWhitelistUpdated(_pair, _account, _status);
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "Identical addresses");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(getPair[token0][token1] == address(0), "Pair exists");

        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {pair := create2(0, add(bytecode, 32), mload(bytecode), salt)}

        UniswapV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setRouter(address _pair) external {
        address router = IRootDispatch(owner).getSubContractAddress("SWAP_ROUTER");
        UniswapV2Pair(_pair).setRouter(router);
        emit RouterSet(_pair, router);
    }

    function setTreasury(address _pair) external onlyManager {
        address treasury = IRootDispatch(owner).getSubContractAddress("TREASURY");
        UniswapV2Pair(_pair).setTreasury(treasury);
    }

    function setAutoForwarder(address _pair, address _autoForwarder) external onlyManager {
        UniswapV2Pair(_pair).setAutoForwarder(_autoForwarder);
    }

    function getPairUnsorted(address tokenA, address tokenB) external view returns (address) {
        (address token0, address token1) = TokenUtils.sortTokens(tokenA, tokenB);
        return getPair[token0][token1];
    }

    /* ---- 修饰符 ---- */
    modifier onlyManager() {
        require(msg.sender == manager, "Only Manager");
        _;
    }
}

/* ──────────────────────────────── UniswapV2Router ──────────────────────────────── */
contract UniswapV2Router is ReentrancyGuard {
    address public factory;
    address public owner;
    address public treasury;
    address public autoForwarder;

    uint256 public lastSwapTime;
    uint256 public constant SWAP_COOLDOWN = 10 seconds;

    event LiquidityAdded(address indexed pair, uint256 amountA, uint256 amountB, uint256 liquidity);

    constructor(address _factory, address _owner) {
        factory = _factory;
        owner = _owner;
        lastSwapTime = block.timestamp;
    }

    /* ---- admin ---- */
    function setTreasury(address _treasury) external onlyFactory {
        require(_treasury != address(0), "invalid address");
        treasury = _treasury;
    }

    function setAutoForwarder(address _autoForwarder) external onlyFactory {
        require(_autoForwarder != address(0), "invalid address");
        autoForwarder = _autoForwarder;
    }

    /* ====================================================================== *
                                │  添加流动性 │
     * ====================================================================== */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256 liquidity) {
        require(deadline >= block.timestamp, "EXPIRED");

        _safeTransferFrom(tokenA, msg.sender, address(this), amountADesired);
        _safeTransferFrom(tokenB, msg.sender, address(this), amountBDesired);

        (address token0, address token1) = TokenUtils.sortTokens(tokenA, tokenB);
        address pair = UniswapV2Factory(factory).getPair(token0, token1);
        if (pair == address(0)) pair = UniswapV2Factory(factory).createPair(tokenA, tokenB);
        // 4. 同步储备
        UniswapV2Pair(pair).sync();
        (uint256 amountA, uint256 amountB) = _calculateLiquidity(tokenA, tokenB, amountADesired, amountBDesired);

        require(amountA >= amountAMin, "amountA < min");
        require(amountB >= amountBMin, "amountB < min");

        _safeTransfer(tokenA, pair, amountA);
        _safeTransfer(tokenB, pair, amountB);

        liquidity = UniswapV2Pair(pair).mint(to);

        if (amountADesired > amountA) _safeTransfer(tokenA, msg.sender, amountADesired - amountA);
        if (amountBDesired > amountB) _safeTransfer(tokenB, msg.sender, amountBDesired - amountB);

        emit LiquidityAdded(pair, amountA, amountB, liquidity);
    }

    /* ---- liquidity helpers ---- */
    function _calculateLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired
    ) internal view returns (uint256 amountA, uint256 amountB) {
        (uint256 reserveA, uint256 reserveB) = _getReservesSorted([tokenA, tokenB]);
        if (reserveA == 0 || reserveB == 0) {
            amountA = amountADesired;
            amountB = amountBDesired;
        } else {
            uint256 tokenBRequired = (amountADesired * reserveB) / reserveA;
            if (tokenBRequired <= amountBDesired) {
                amountA = amountADesired;
                amountB = tokenBRequired;
            } else {
                uint256 tokenARequired = (amountBDesired * reserveA) / reserveB;
                amountA = tokenARequired;
                amountB = amountBDesired;
            }
        }
    }

    function calculateLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired
    ) external view returns (uint256, uint256) {
        return _calculateLiquidity(tokenA, tokenB, amountADesired, amountBDesired);
    }

    /* ====================================================================== *
                                │  Swap │
     * ====================================================================== */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256[] memory amounts) {
        return _swapExactTokensForTokens(amountIn, amountOutMin, path, to, deadline);
    }

    function autoForwarderSwapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external onlyAutoForwarder returns (uint256[] memory amounts) {
        return _swapExactTokensForTokens(amountIn, amountOutMin, path, to, deadline);
    }

    function _swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) private returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "EXPIRED");
        // 防止恶意长路径攻击
        require(path.length == 2, "Invalid path");

        (address token0, address token1) = TokenUtils.sortTokens(path[0], path[1]);
        address pair = UniswapV2Factory(factory).getPair(token0, token1);
        require(path[1] != IRootDispatch(owner).getSubContractAddress("AMD_TOKEN") || msg.sender == treasury || msg.sender == autoForwarder, "Invalid path");
        uint256 before = IERC20(path[0]).balanceOf(pair);
        _safeTransferFrom(path[0], msg.sender, pair, amountIn);
        uint256 realAmountIn = IERC20(path[0]).balanceOf(pair) - before;
        amounts = getAmountsOut(realAmountIn, path, to);
        require(amounts[amounts.length - 1] >= amountOutMin, "Slippage exceeded");
        _swap(amounts, path, to);

        // 根据 DIA‑TOKEN / 目标汇率自动平衡
        if (path[0] == IRootDispatch(owner).getSubContractAddress("DIA_TOKEN")) {
            (uint256 reserve0, uint256 reserve1) = _getReservesSorted([path[0], path[1]]);
            if (getExchangeRate(reserve0, reserve1) < 1e6) {
                uint256 targetIn = _calculateSwapAmount(reserve0, reserve1);
                IMint(IRootDispatch(owner).getSubContractAddress("MINT")).swapToken(path[1], path[0], targetIn);
            }
        }
    }

    /* ---- volatility helper ---- */
    function _calculateSwapAmount(uint256 reserveA, uint256 reserveB) internal pure returns (uint256 x) {
        if (reserveA >= reserveB) return 0;
        uint256 k = reserveA * reserveB;
        uint256 sqrtK = sqrt(k);
        x = sqrtK - reserveA;

        uint256 adjustedA = reserveA + x;
        uint256 adjustedB = k / adjustedA;
        if (adjustedA <= adjustedB) x += 1;
    }

    function getExchangeRate(uint256 reserveA, uint256 reserveB) public pure returns (uint256) {
        require(reserveA > 0 && reserveB > 0, "No liquidity");
        return (reserveB * 1e6) / reserveA;
    }

    // /* ---- quote helpers ---- */
    // function getAmountOutInner(uint256 amountIn, address[] memory path) internal view returns (uint256 amountOut) {
    //     require(path.length == 2, "Invalid path");
    //     uint256 current = amountIn;
    //     for (uint256 i; i < path.length - 1; i++) {
    //         (address token0, address token1) = TokenUtils.sortTokens(path[i], path[i + 1]);
    //         address pair = UniswapV2Factory(factory).getPair(token0, token1);
    //         (uint256 reserve0, uint256 reserve1) = _getReserves(pair);
    //         bool isInput0 = (path[i] == token0);
    //         uint256 reserveIn = isInput0 ? reserve0 : reserve1;
    //         uint256 reserveOut = isInput0 ? reserve1 : reserve0;
    //         uint256 amountInWithFee = current * (10_000 - 25) / 10_000;
    //         uint256 out = (amountInWithFee * reserveOut) / (reserveIn + amountInWithFee);
    //         current = out;
    //     }
    //     amountOut = current;
    // }

    function getAmountsOut(uint256 amountIn, address[] calldata path, address to) public view returns (uint256[] memory amounts) {
        require(path.length == 2, "Invalid path");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        for (uint256 i; i < path.length - 1; i++) {
            (address token0, address token1) = TokenUtils.sortTokens(path[i], path[i + 1]);
            address pair = UniswapV2Factory(factory).getPair(token0, token1);
            (uint256 reserve0, uint256 reserve1) = _getReserves(pair);
            bool isInput0 = (path[i] == token0);
            uint256 reserveIn = isInput0 ? reserve0 : reserve1;
            uint256 reserveOut = isInput0 ? reserve1 : reserve0;

            bool isFeeFree = UniswapV2Pair(pair).feeWhitelist(to) || to == treasury;
            uint256 feeNumerator = isFeeFree ? 10_000 : (10_000 - 25); // 0.25% fee if not white
            uint256 amountInWithFee = amounts[i] * feeNumerator / 10_000;
            amounts[i + 1] = (amountInWithFee * reserveOut) / (reserveIn + amountInWithFee);
        }
    }

    /* ---- internal swap loop ---- */
    function _swap(uint256[] memory amounts, address[] memory path, address to) internal {
        for (uint256 i; i < path.length - 1; i++) {
            (address token0, address token1) = TokenUtils.sortTokens(path[i], path[i + 1]);
            bool isInput0 = (path[i] == token0);

            uint256 amountOut = amounts[i + 1];
            uint256 amount0Out = isInput0 ? 0 : amountOut;
            uint256 amount1Out = isInput0 ? amountOut : 0;

            address pair = UniswapV2Factory(factory).getPair(token0, token1);
            UniswapV2Pair(pair).swap(
                amount0Out,
                amount1Out,
                i == path.length - 2 ? to : address(this)
            );
        }
    }

    /* ---- views ---- */
    function getReserves(address pair) external view returns (uint256, uint256) {return _getReserves(pair);}

    function getReservesByPath(address[2] calldata path) external view returns (uint256, uint256) {
        return _getReservesSorted(path);
    }

    function getTotalSupply(address pair) external view returns (uint256) {return UniswapV2Pair(pair).totalSupply();}

    /* ---- internal helpers ---- */
    function _getReserves(address pair) internal view returns (uint256, uint256) {
        (uint112 r0, uint112 r1,) = UniswapV2Pair(pair).getReserves(); // --- patched: 取前两项
        return (uint256(r0), uint256(r1));
    }

    function _getReservesSorted(address[2] memory path) internal view returns (uint256, uint256) {
        (address token0, address token1) = TokenUtils.sortTokens(path[0], path[1]);
        address pair = UniswapV2Factory(factory).getPair(token0, token1);
        require(pair != address(0), "Invalid pair");
        (uint256 r0, uint256 r1) = _getReserves(pair);
        return token0 == path[0] ? (r0, r1) : (r1, r0);
    }

    /* ---- safe transfers ---- */
    function _safeTransfer(address token, address to, uint256 amount) private {
        require(token != address(0), "Zero token"); // --- patched
        require(token.code.length > 0, "Not contract");
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "Transfer failed");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        require(token != address(0), "Zero token"); // --- patched
        require(token.code.length > 0, "Not contract");
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TransferFrom failed");
    }

    /* ---- misc math ---- */
    function sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {z = y;
            uint256 x = (y >> 1) + 1;
            while (x < z) {z = x;
                x = (y / x + x) >> 1;}
        } else if (y != 0) {z = 1;}
    }

    /* ---- modifier ---- */
    modifier onlyFactory()    {require(msg.sender == factory, "Only Factory");
        _;}

    modifier onlyAutoForwarder()    {require(msg.sender == autoForwarder, "Only AutoForwarder");
        _;}
}
