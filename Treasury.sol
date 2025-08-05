// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

// 定义 ERC20 合约接口
interface IERC20 {
    function mint(address to, uint256 value) external;

    function transfer(address to, uint256 value) external returns (bool);

    function approve(address spender, uint256 value) external returns (bool);

    function burn(address from, uint256 value) external;

    function allowance(address owner, address spender) external view returns (uint256);

    function decimals() external view returns (uint8);
}
// 定义 RootDispatch 合约的接口

interface IRootDispatch {
    function getSubContractAddress(string memory _name) external view returns (address);
}
// 定义 Swap 合约的接口

interface ISwapRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 liquidity);
}
// 定义ArbSys合约接口

interface ArbSys {
    function arbBlockNumber() external view returns (uint256);
}
// 国库合约

contract Treasury {
    ArbSys constant arbsys = ArbSys(address(100));
    // 管理员地址
    address public manager;
    // 主合约地址
    address public managerContract;
    // DIA 合约地址
    address public diaContract;
    // AMD 合约地址
    address public amdContract;
    // router 合约地址
    address public routerContract;
    // factory 合约地址
    address public factoryContract;
    // mint 合约地址
    address public mintContract;
    // staking 合约地址
    address public stakingContract;
    // amd 释放合约地址
    address public amdReleaseContract;
    // dia 行权合约地址
    address public diaExerciseContract;
    // usdt 合约地址
    address public usdtContract;
    // referral 合约地址
    address public referralContract;
    // init tag
    // uint256 public initTag;

    // 铸造记录结构体
    struct UserMint {
        uint256 totalAmount;
        uint256 withdrewAmount;
        uint256 createHeight;
        uint8 mintType; // 铸造类型 0-usdt 1-lp
    }

    mapping(address => mapping(uint256 => UserMint)) public userMints;
    mapping(address => uint256) public userMintCount;

    // 收益率map 波动在10/10000到30/10000之间
    mapping(uint256 => uint256) public rateOfBlock;
    uint256 public latestRebaseBlock;
    uint256[] public rateBlocks;

    // 用户staking结构体
    struct UserStaking {
        uint256 stakingAmount;
        uint256 currentDDIAAmount; // 最近一次更新后剩余ddia量
        uint256 totalDDIAAmount; // 最近一次更新后已行权ddia总量
        uint256 createHeight;
        uint256 recordHeight;
        uint256 usdtValue; // u本位价值
        address[] referrers;
        uint256[] referrerAMDIndexes;
    }

    mapping(address => mapping(uint256 => UserStaking)) public userStakings;
    mapping(address => uint256) public userStakingCount;
    mapping(address => uint256) public totalUserStaking;
    mapping(address => uint256) public userBranchCount;

    // 用户ddia行权dia记录结构体
    struct UserDIAExercise {
        uint256 dAmount;
        uint256 withdrewAmount;
        uint256 createHeight;
        uint256 accelerateTime;
    }

    mapping(address => mapping(uint256 => UserDIAExercise)) public userDIAExercises;
    mapping(address => uint256) public userDIAExerciseCount;

    // 部署时指定主合约地址并从主合约获取代币合约地址
    constructor(address _manager) {
        manager = msg.sender;
        managerContract = _manager;
        diaContract = IRootDispatch(managerContract).getSubContractAddress("DIA_TOKEN");
        amdContract = IRootDispatch(managerContract).getSubContractAddress("AMD_TOKEN");
        routerContract = IRootDispatch(managerContract).getSubContractAddress("SWAP_ROUTER");
        factoryContract = IRootDispatch(managerContract).getSubContractAddress("SWAP_FACTORY");
        mintContract = IRootDispatch(managerContract).getSubContractAddress("MINT");
        stakingContract = IRootDispatch(managerContract).getSubContractAddress("STAKING");
        amdReleaseContract = IRootDispatch(managerContract).getSubContractAddress("AMD_RELEASE");
        diaExerciseContract = IRootDispatch(managerContract).getSubContractAddress("DIA_EXERCISE");
        referralContract = IRootDispatch(managerContract).getSubContractAddress("REFERRAL");
        usdtContract = address(0x22D70Fbd6cbae9D217a5453b7488704F4D35f72C);
        IERC20(usdtContract).approve(routerContract, type(uint256).max);
        IERC20(diaContract).approve(routerContract, type(uint256).max);
        IERC20(amdContract).approve(routerContract, type(uint256).max);
        // initTag = 0;
    }

    receive() external payable {}

    fallback() external payable {}

    // modifier onlyInit() {
    //     require(initTag == 0, "Pool already init before");
    //     _;
    // }

    modifier onlyContract(address allowedContracts) {
        require(msg.sender == allowedContracts, "Caller is not an allowed contract");
        _;
    }

    modifier allInternalContract() {
        require(
            msg.sender == manager || msg.sender == managerContract || msg.sender == mintContract
            || msg.sender == stakingContract || msg.sender == amdReleaseContract || msg.sender == diaExerciseContract,
            "Caller must be Internal Contract"
        );
        _;
    }

    function changeManager(address _to) external onlyContract(manager) {
        manager = _to;
    }

    // 刷新合约地址
    function refreshContract() external allInternalContract {
        diaContract = IRootDispatch(managerContract).getSubContractAddress("DIA_TOKEN");
        amdContract = IRootDispatch(managerContract).getSubContractAddress("AMD_TOKEN");
        routerContract = IRootDispatch(managerContract).getSubContractAddress("SWAP_ROUTER");
        factoryContract = IRootDispatch(managerContract).getSubContractAddress("SWAP_FACTORY");
        mintContract = IRootDispatch(managerContract).getSubContractAddress("MINT");
        stakingContract = IRootDispatch(managerContract).getSubContractAddress("STAKING");
        amdReleaseContract = IRootDispatch(managerContract).getSubContractAddress("AMD_RELEASE");
        diaExerciseContract = IRootDispatch(managerContract).getSubContractAddress("DIA_EXERCISE");
        referralContract = IRootDispatch(managerContract).getSubContractAddress("REFERRAL");
        IERC20(usdtContract).approve(routerContract, type(uint256).max);
        IERC20(diaContract).approve(routerContract, type(uint256).max);
        IERC20(amdContract).approve(routerContract, type(uint256).max);
    }

    // 铸造dia
    function mintDIA(uint256 _amount) external allInternalContract {
        IERC20(diaContract).mint(address(this), _amount);
    }

    // 铸造amd
    function mintAMD(uint256 _amount) external allInternalContract {
        IERC20(amdContract).mint(address(this), _amount);
    }

    // swap购买代币
    function swapToken(uint256 _amountIn, uint256 _amountOutMin, address[] calldata _path)
    external
    allInternalContract
    returns (uint256[] memory amounts)
    {
        return ISwapRouter(routerContract).swapExactTokensForTokens(
            _amountIn, _amountOutMin, _path, address(this), block.timestamp + 5 minutes
        );
    }
    // swap添加流动性

    function addLiquidity(
        address _tokenA,
        address _tokenB,
        uint256 _amountADesired,
        uint256 _amountBDesired,
        uint256 _amountAMin,
        uint256 _amountBMin,
        address _to
    ) external allInternalContract returns (uint256 liquidity) {
        return ISwapRouter(routerContract).addLiquidity(
            _tokenA,
            _tokenB,
            _amountADesired,
            _amountBDesired,
            _amountAMin,
            _amountBMin,
            _to,
            block.timestamp + 5 minutes
        );
    }

    // 添加铸造记录方法
    function addUserMint(address _user, uint256 _amount, uint8 _mintType) external onlyContract(mintContract) {
        uint256 index = userMintCount[_user]; // 获取当前用户的 index
        userMints[_user][index] = UserMint({
            totalAmount: _amount,
            withdrewAmount: 0,
            createHeight: arbsys.arbBlockNumber(),
            mintType: _mintType
        });
        userMintCount[_user]++; // 递增用户记录数
    }

    // 获取铸造记录方法
    function getUserMint(address _user, uint256 _index)
    external
    view
    returns (uint256 totalAmount, uint256 withdrewAmount, uint256 createHeight, uint8 mintType)
    {
        // 读取用户铸造记录
        UserMint memory record = userMints[_user][_index];
        return (record.totalAmount, record.withdrewAmount, record.createHeight, record.mintType);
    }

    // 修改铸造记录方法
    function updateUserMint(address _user, uint256 _index, uint256 _withdrewAmount) external allInternalContract {
        UserMint storage record = userMints[_user][_index];
        record.withdrewAmount = _withdrewAmount;
    }

    // 向用户转出 DIA
    function transferDIA(address _user, uint256 _amount) external allInternalContract {
        require(IERC20(diaContract).transfer(_user, _amount), "DIA transfer failed");
    }

    // 向用户转出 AMD
    function transferAMD(address _user, uint256 _amount) external allInternalContract {
        require(IERC20(amdContract).transfer(_user, _amount), "AMD transfer failed");
    }

    // 向用户转出 USDT
    function transferUSDT(address _user, uint256 _amount) external onlyContract(manager) {
        require(IERC20(usdtContract).transfer(_user, _amount), "USDT transfer failed");
    }

    // burn AMD
    function burnAMD(uint256 _amount) external allInternalContract {
        IERC20(amdContract).burn(address(this), _amount);
    }

    // 添加staking记录方法
    function addUserStaking(
        address _user,
        uint256 _amount,
        uint256 _usdtValue,
        address[] memory _referrers,
        uint256[] memory _indexes
    ) external onlyContract(stakingContract) {
        uint256 stakingId = userStakingCount[_user];

        userStakings[_user][stakingId] = UserStaking({
            stakingAmount: _amount,
            currentDDIAAmount: 0,
            totalDDIAAmount: 0,
            createHeight: arbsys.arbBlockNumber(),
            recordHeight: arbsys.arbBlockNumber(),
            usdtValue: _usdtValue,
            referrers: _referrers,
            referrerAMDIndexes: _indexes
        });

        userStakingCount[_user]++;
        totalUserStaking[_user] += _usdtValue;
    }

    // 更改用户枝数量方法
    function updateUserBranchCount(address _user, uint256 _count) external onlyContract(stakingContract) {
        userBranchCount[_user] = _count;
    }

    // 获取staking记录方法
    function getUserStaking(address _user, uint256 _index)
    external
    view
    returns (
        uint256 stakingAmount,
        uint256 currentDDIAAmount,
        uint256 totalDDIAAmount,
        uint256 recordHeight,
        uint256 usdtValue,
        address[] memory referrers,
        uint256[] memory referrerAMDIndexes
    )
    {
        // 读取用户staking记录
        UserStaking memory record = userStakings[_user][_index];
        return (
            record.stakingAmount,
            record.currentDDIAAmount,
            record.totalDDIAAmount,
            record.recordHeight,
            record.usdtValue,
            record.referrers,
            record.referrerAMDIndexes
        );
    }

    // 修改staking记录方法
    function updateUserStaking(
        address _user,
        uint256 _index,
        uint256 _stakingAmount,
        uint256 _currentDDIAAmount,
        uint256 _totalDDIAAmount
    ) external allInternalContract {
        UserStaking storage record = userStakings[_user][_index];
        record.stakingAmount = _stakingAmount;
        record.currentDDIAAmount = _currentDDIAAmount;
        record.totalDDIAAmount = _totalDDIAAmount;
        record.recordHeight = arbsys.arbBlockNumber();
        if (_stakingAmount == 0) {
            totalUserStaking[_user] -= record.usdtValue;
            record.usdtValue = 0;
        }
    }

    // 添加行权dia记录方法 _accelerateTime 加速次数
    function addUserDIAExercise(address _user, uint256 _amount, uint256 _accelerateTime)
    external
    onlyContract(diaExerciseContract)
    {
        uint256 userDIAExerciseId = userDIAExerciseCount[_user];
        userDIAExercises[_user][userDIAExerciseId] = UserDIAExercise({
            dAmount: _amount,
            withdrewAmount: 0,
            createHeight: arbsys.arbBlockNumber(),
            accelerateTime: _accelerateTime
        });
        userDIAExerciseCount[_user]++; // 递增用户行权记录数
    }

    // 获取行权dia记录方法
    function getUserDIAExercise(address _user, uint256 _index)
    external
    view
    returns (uint256 dAmount, uint256 withdrewAmount, uint256 createHeight, uint256 accelerateTime)
    {
        UserDIAExercise storage record = userDIAExercises[_user][_index];
        return (record.dAmount, record.withdrewAmount, record.createHeight, record.accelerateTime);
    }

    // 修改行权dia记录方法
    function updateUserDIAExercise(address _user, uint256 _index, uint256 _withdrewAmount, uint256 _accelerateTime)
    external
    onlyContract(diaExerciseContract)
    {
        UserDIAExercise storage record = userDIAExercises[_user][_index];
        record.withdrewAmount = _withdrewAmount;
        record.accelerateTime = _accelerateTime;
    }

    // 获取收益率map
    function getRateBlocks() external view returns (uint256[] memory) {
        return rateBlocks;
    }

    // 更新收益率
    function rebaseRate(uint256 _rate) external onlyContract(manager) {
        if (latestRebaseBlock >= arbsys.arbBlockNumber()) {
            return;
        }

        // 如果新收益率和上次相同，则不重复存储
        if (rateBlocks.length > 0) {
            uint256 lastBlock = rateBlocks[rateBlocks.length - 1];
            if (rateOfBlock[lastBlock] == _rate) {
                latestRebaseBlock = arbsys.arbBlockNumber();
                return;
            }
        }
        rateOfBlock[arbsys.arbBlockNumber()] = _rate;
        rateBlocks.push(arbsys.arbBlockNumber());
        latestRebaseBlock = arbsys.arbBlockNumber();
    }
}
