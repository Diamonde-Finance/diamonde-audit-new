// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
// 定义 RootDispatch 合约的接口

interface IRootDispatch {
    function getSubContractAddress(string memory _name) external view returns (address);
}

contract AMD {
    string public name;
    string public symbol;
    uint8 public decimals = 6;
    uint256 public totalSupply;
    uint256 public burnSupply;
    address public owner;
    address manager;
    address public admin;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // 部署时指定代币名称、符号和初始供应量
    constructor(string memory _name, string memory _symbol, address _owner) {
        name = _name;
        symbol = _symbol;
        owner = _owner;
        admin = msg.sender;
        totalSupply = 0; // 正确初始化
        burnSupply = 0;
        manager = IRootDispatch(owner).getSubContractAddress("TREASURY");
        require(manager != address(0), "Invalid manager address");
    }
    // 转账函数

    function transfer(address to, uint256 value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "Insufficient balance");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }
    // 授权函数

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    // 授权转账函数
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(balanceOf[from] >= value, "Insufficient balance");
        require(allowance[from][msg.sender] >= value, "Allowance exceeded");

        balanceOf[from] -= value;
        balanceOf[to] += value;
        allowance[from][msg.sender] -= value;

        emit Transfer(from, to, value);
        return true;
    }

    function burn(address from, uint256 value) external onlyAuthorized returns (bool) {
        if (totalSupply == 210000 * 1e6 && totalSupply - burnSupply - value <= 21000 * 1e6) {
            return false;
        }
        if (totalSupply - burnSupply - value <= 0) {
            return false;
        }
        _burn(from, value);
        return true;
    }

    function _burn(address from, uint256 value) private {
        balanceOf[from] -= value;
        burnSupply += value;
    }
    // 私有铸造函数（仅部署时使用）

    function _mint(address to, uint256 value) private returns (bool) {
        balanceOf[to] += value;
        totalSupply += value;
        emit Transfer(address(0), to, value);
        return true;
    }
    // 可选：测试时快速增发代币（仅供测试用！）

    function mint(address to, uint256 value) external onlyAuthorized returns (bool) {
        if (totalSupply + value <= 210000 * 1e6) {
            return _mint(to, value);
        }
        return false;
    }

    function quitManager() external onlyAuthorized {
        admin = address(0);
    }

    modifier onlyAuthorized() {
        manager = IRootDispatch(owner).getSubContractAddress("TREASURY");
        require(msg.sender == manager || msg.sender == admin, "Caller must be Manager");
        _;
    }
}
