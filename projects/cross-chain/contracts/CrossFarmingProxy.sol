// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IMasterChefV2.sol";
import "./interfaces/IMintable.sol";

/// @title A proxy contract that stake LP tokens on behalf of users to MCV2 farm pools,
/// @dev auto deployed on BSC chain by receiver contract(factory) during user 1st cross farming transaction.
contract CrossFarmingProxy is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // cross-chain user address.
    address public user;
    // CAKE token.
    address public CAKE;
    // cross-farming receiver contract on BSC chain.
    address public immutable factory;
    // MCV2 contract.
    IMasterChefV2 public MASTER_CHEF_V2;

    /// @notice used nonce (pid => (nonce => bool))
    mapping(uint256 => mapping(uint64 => bool)) public usedNonce;
    /// @notice (pid => amount)).
    mapping(uint256 => uint256) public userInfo;
    /// @notice whether user approved LP token to MCV2
    mapping(address => bool) public approved;

    event Harvest(address indexed user, uint256 pid);
    event FallbackDeposit(address indexed user, uint256 pid, uint64 nonce);
    event FallbackWithdraw(address indexed user, uint256 pid, uint256 amount, uint64 nonce);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount, uint64 nonce);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount, uint64 nonce);
    event EmergencyWithdraw(address indexed caller, uint256 indexed pid, uint256 amount, uint64 nonce);

    constructor() {
        factory = msg.sender;
    }

    modifier onlyFactory() {
        require(msg.sender == factory, "not factory");
        _;
    }

    modifier onlyNotUsedNonce(uint256 _pid, uint64 _nonce) {
        require(!usedNonce[_pid][_nonce], "used nonce");
        _;
    }

    /**
     * @param _user cross-chain user address.
     * @param _cake CAKE token address.
     * @param _mcv2 MasterchefV2 address.
     */
    function initialize(
        address _user,
        address _cake,
        IMasterChefV2 _mcv2
    ) external {
        require(msg.sender == factory, "initialize: FORBIDDEN");
        user = _user;
        CAKE = _cake;
        MASTER_CHEF_V2 = _mcv2;
    }

    /**
     * @notice Deposit LP tokens to pool.
     * @param _pid pool id in in MCV2.
     * @param _amount staked LP token amount.
     * @param _nonce the user nonce in specific pool.
     */
    function deposit(
        uint256 _pid,
        uint256 _amount,
        uint64 _nonce
    ) external nonReentrant onlyFactory onlyNotUsedNonce(_pid, _nonce) {
        address lpToken = MASTER_CHEF_V2.lpToken(_pid);

        if (!approved[lpToken]) {
            IERC20(lpToken).approve(address(MASTER_CHEF_V2), type(uint256).max);
            approved[lpToken] = true;
        }

        // In case multiple deposits deplete the allowance.
        if (IERC20(lpToken).allowance(address(this), address(MASTER_CHEF_V2)) <= _amount) {
            // re-approve
            IERC20(lpToken).approve(address(MASTER_CHEF_V2), type(uint256).max);
        }

        MASTER_CHEF_V2.deposit(_pid, _amount);
        // send CAKE reward
        _safeTransfer(user);

        // update state
        userInfo[_pid] += _amount;

        // mark nonce used
        usedNonce[_pid][_nonce] = true;

        emit Deposit(user, _pid, _amount, _nonce);
    }

    /**
     * @notice Withdraw LP tokens from pool.
     * @param _pid pool id in in MCV2.
     * @param _amount withdraw LP token amount.
     * @param _nonce the user nonce in specific pool.
     */
    function withdraw(
        uint256 _pid,
        uint256 _amount,
        uint64 _nonce
    ) external nonReentrant onlyFactory onlyNotUsedNonce(_pid, _nonce) {
        require(userInfo[_pid] >= _amount && _amount > 0, "Insufficient token");

        // withdraw from MCV2 pool
        MASTER_CHEF_V2.withdraw(_pid, _amount);
        // burn LP token which equal to withdraw amount
        IMintable(MASTER_CHEF_V2.lpToken(_pid)).burn(_amount);
        // send CAKE reward
        _safeTransfer(user);

        // update state
        userInfo[_pid] -= _amount;

        // mark nonce used
        usedNonce[_pid][_nonce] = true;

        emit Withdraw(user, _pid, _amount, _nonce);
    }

    /**
     * @notice Withdraw without caring about the rewards. EMERGENCY ONLY.
     * @param _pid pool id in in MCV2.
     * @param _nonce the user nonce in specific pool.
     */
    function emergencyWithdraw(uint256 _pid, uint64 _nonce)
        external
        nonReentrant
        onlyFactory
        onlyNotUsedNonce(_pid, _nonce)
    {
        uint256 amount = userInfo[_pid];
        require(amount > 0, "No token left");

        // withdraw all staked LP token from MCV2 pool
        MASTER_CHEF_V2.emergencyWithdraw(_pid);
        // burn LP token which euqal to user all staked amount
        IMintable(MASTER_CHEF_V2.lpToken(_pid)).burn(amount);

        // update state
        userInfo[_pid] = 0;

        // mark nonce used
        usedNonce[_pid][_nonce] = true;

        emit EmergencyWithdraw(user, _pid, amount, _nonce);
    }

    /**
     * @notice claim CAKE reward in MCV2 farm pool.
     * @param _pid pool id in materchef pool. NOT vault contract pool pid on EVM chain.
     */
    function harvest(uint256 _pid) external nonReentrant {
        require(userInfo[_pid] > 0, "No token to harvest");

        // withdraw all staked LP token from MCV2 pool
        MASTER_CHEF_V2.deposit(_pid, 0);
        // send CAKE reward
        _safeTransfer(user);

        emit Harvest(user, _pid);
    }

    /// @dev only called by factory when user deposit success on EVM chain but failed on BSC chain.
    /// @notice after call this function, operator still need to call 'fallbackDeposit' on vault contract deployed on EVM
    function fallbackDeposit(uint256 _pid, uint64 _nonce) external onlyFactory onlyNotUsedNonce(_pid, _nonce) {
        // only mark nonce used
        usedNonce[_pid][_nonce] = true;

        emit FallbackDeposit(user, _pid, _nonce);
    }

    /// @dev only called by factory when user withdraw/emergencywithdraw success on EVM chain but failed on BSC chain
    /// @notice after call this function, operator still need call 'fallbackWithdraw' on vault contract deployed on EVM
    function fallbackWithdraw(
        uint256 _pid,
        uint256 _amount,
        uint64 _nonce
    ) external onlyFactory onlyNotUsedNonce(_pid, _nonce) {
        require(userInfo[_pid] >= _amount && _amount > 0, "Insufficient token");

        // withdraw from MCV2 pool
        MASTER_CHEF_V2.withdraw(_pid, _amount);
        // burn LP token which equal to withdraw amount
        IMintable(MASTER_CHEF_V2.lpToken(_pid)).burn(_amount);
        // send CAKE reward
        _safeTransfer(user);

        userInfo[_pid] -= _amount;
        // mark nonce used
        usedNonce[_pid][_nonce] = true;

        emit FallbackWithdraw(user, _pid, _amount, _nonce);
    }

    function _safeTransfer(address _to) internal {
        uint256 balance = IERC20(CAKE).balanceOf(address(this));
        if (balance > 0) {
            IERC20(CAKE).safeTransfer(_to, balance);
        }
    }
}
