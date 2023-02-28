// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "sgn-v2-contracts/contracts/message/framework/MessageSenderApp.sol";
import "sgn-v2-contracts/contracts/message/framework/MessageReceiverApp.sol";
import "./interfaces/IMasterChefV2.sol";
import "./libraries/DataTypes.sol";
import "./CrossFarmingProxy.sol";

/// @title A cross chain receiver contract deployed on BSC chain. receive the sender contract call from other EVM chain.
// It's for users from other EVM chain can participate Pancakeswap MCV2 farm pool CAKE reward in BSC chain.
contract CrossFarmingReceiver is MessageSenderApp, MessageReceiverApp {
    using SafeERC20 for IERC20;

    // CAKE token.
    address public immutable CAKE;
    // cross farming contract on EVM chain.
    address public immutable CROSS_FARMING_SENDER;
    // the operator for fallback(deposit/withdraw) operation.
    address public operator;
    // MCV2 contract.
    IMasterChefV2 public immutable MASTER_CHEF_V2;

    // Small BNB change for the new user in BSC chain.
    uint256 public BNB_CHANGE = 0.005 ether;
    // EVM chain ID
    uint64 public immutable SENDER_CHAIN_ID;

    // whether user receive BNB change(0.005 BNB)
    mapping(address => bool) public bnbChangeReceived;
    // user proxy => user account
    mapping(address => address) public uProxy;
    // user account => proxy
    mapping(address => address) public cProxy;

    event BnbChangeUpdated(uint256 amount);
    event FeeClaimed(uint256 amount, bool success);
    event ProxyCreated(address indexed sender, address proxy);
    event FallbackDeposit(address indexed user, uint256 pid, uint64 nonce);
    event FallbackWithdraw(address indexed user, uint256 pid, uint256 amount, uint64 nonce);
    event OperatorUpdated(address indexed newOperator, address indexed oldOperator);
    event FarmingMessageReceived(
        address sender,
        uint64 srcChainId,
        uint64 nonce,
        DataTypes.MessageTypes msgType,
        address acount,
        uint256 pid,
        uint256 amount
    );

    constructor(
        address _messageBus,
        address _cake,
        address _sender,
        IMasterChefV2 _mcv2,
        address _operator,
        uint64 _chainId
    ) {
        messageBus = _messageBus;
        CAKE = _cake;
        CROSS_FARMING_SENDER = _sender;
        MASTER_CHEF_V2 = _mcv2;
        operator = _operator;
        SENDER_CHAIN_ID = _chainId;
    }

    /// receive BNB to send 0.005 BNB for fresh user.
    receive() external payable {}

    modifier onlyOperator() {
        require(msg.sender == operator, "not cross farming sender");
        _;
    }

    /**
     * @notice Only called by MessageBus
     * @param _sender The address of the source chain contract
     * @param _srcChainId The source chain ID where the transfer is originated from
     * @param _message Encoded CrossFarmingRequest message bytes.
     */
    function executeMessage(
        address _sender,
        uint64 _srcChainId,
        bytes calldata _message,
        address // executor who called the MessageBus execution function
    ) external payable override onlyMessageBus returns (ExecutionStatus) {
        require(_srcChainId == SENDER_CHAIN_ID && _sender == CROSS_FARMING_SENDER, "Invalid sender contract");

        // decode the message
        DataTypes.CrossFarmRequest memory request = abi.decode((_message), (DataTypes.CrossFarmRequest));

        address proxy = cProxy[request.account];

        if (proxy == address(0)) {
            // In extremely situation, user 1st deposit tx maybe failed to sent to receiver contract
            // If this user continue to send 2nd withdraw tx and success to call this function
            // the 'proxy' contract still be zero, 'withdraw' must be failed, So, only 'Deposit' Tx allowed.
            require(request.msgType == DataTypes.MessageTypes.Deposit, "1st tx should be deposit");
            // create proxy contract for 1st participate cross-farming user.
            proxy = _createProxy(request.account);
        }

        if (request.msgType == DataTypes.MessageTypes.Deposit) {
            // Mint LP token for user proxy contract.
            IMintable(MASTER_CHEF_V2.lpToken(request.pid)).mint(address(proxy), request.amount);
            CrossFarmingProxy(proxy).deposit(request.pid, request.amount, request.nonce);
            // send BNB CHANGE to new cross-farming user
            // can't according nonce == 0 to sent BNB CHANGE, if contract balance < BNB_CHANGE in exetremely situation
            // it will not send the CHANGE fee to user, the user will not receive the CHANGE forever.
            if (!bnbChangeReceived[request.account] && address(this).balance >= BNB_CHANGE) {
                // request.account is EOA address.
                payable(request.account).transfer(BNB_CHANGE);
                bnbChangeReceived[request.account] = true;
            }
        } else if (request.msgType == DataTypes.MessageTypes.Withdraw) {
            CrossFarmingProxy(proxy).withdraw(request.pid, request.amount, request.nonce);

            // send ack message back.
            IMessageBus(messageBus).sendMessage{value: IMessageBus(messageBus).calcFee(_message)}(
                _sender,
                _srcChainId,
                _message
            );
        } else if (request.msgType == DataTypes.MessageTypes.EmergencyWithdraw) {
            CrossFarmingProxy(proxy).emergencyWithdraw(request.pid, request.nonce);

            // send ack message back.
            IMessageBus(messageBus).sendMessage{value: IMessageBus(messageBus).calcFee(_message)}(
                _sender,
                _srcChainId,
                _message
            );
        }

        emit FarmingMessageReceived(
            _sender,
            _srcChainId,
            request.nonce,
            request.msgType,
            request.account,
            request.pid,
            request.amount
        );

        return ExecutionStatus.Success;
    }

    /**
     * @notice only when user deposit success on EVM chain but failed on BSC chain.
     * @notice after call this function, operator still need to call 'fallbackDeposit' on vault contract deployed on EVM
     * @param _user user address.
     * @param _pid pool id in MasterchefV2 farm pool.
     * @param _nonce failed nonce.
     */
    function fallbackDeposit(
        address _user,
        uint256 _pid,
        uint64 _nonce
    ) external onlyOperator {
        address proxy = cProxy[_user];
        // call proxy fallbackDeposit
        CrossFarmingProxy(proxy).fallbackDeposit(_pid, _nonce);

        emit FallbackDeposit(_user, _pid, _nonce);
    }

    /**
     * @notice only when user withdraw/emergencywithdraw success on EVM chain but failed on BSC chain.
     * @param _user user address.
     * @param _pid pool id in MasterchefV2 farm pool.
     * @param _amount withdraw token amount.
     * @param _nonce failed nonce.
     */
    function fallbackWithdraw(
        address _user,
        uint256 _pid,
        uint256 _amount,
        uint64 _nonce
    ) external onlyOperator {
        address proxy = cProxy[_user];
        // call proxy fallbackWithdraw
        CrossFarmingProxy(proxy).fallbackWithdraw(_pid, _amount, _nonce);

        emit FallbackWithdraw(_user, _pid, _amount, _nonce);
    }

    // set fallbackwithdraw operator
    function setOperator(address _operator) external onlyOwner {
        require(_operator != address(0), "Operator can't be zero address");
        address temp = operator;
        operator = _operator;

        emit OperatorUpdated(operator, temp);
    }

    /// set BNB change amount for new BSC chain user.
    function setBnbChange(uint256 _change) external onlyOwner {
        require(_change > 0, "BNB change for new user should greater than zero");
        BNB_CHANGE = _change;
        emit BnbChangeUpdated(_change);
    }

    /// transfer any ERC20 token of current contract to owner.
    function drainToken(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    /// send cross-chain sender contract all gas token to owner
    /// @dev unless stop running current contract don't call it, the BNB balance is for send BNB change to new user.
    function claimFee(uint256 _gas) external onlyOwner {
        require(_gas >= 2300, "claimFee gaslimit should exceed 2300 ");

        uint256 amount = address(this).balance;
        (bool success, ) = msg.sender.call{value: amount, gas: _gas}("");

        emit FeeClaimed(amount, success);
    }

    /**
     * @notice When user 1st participate cross-farming, will create a new proxy contract for the user
     * which can stake LP token to MasterchefV2 pool on behalf of the user.
     * @param _user user account.
     */
    function _createProxy(address _user) internal returns (address proxy) {
        require(cProxy[_user] == address(0), "User already has proxy");

        bytes memory bytecode = type(CrossFarmingProxy).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, block.number, _user, SENDER_CHAIN_ID));

        assembly {
            proxy := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        // double check
        require(uProxy[proxy] == address(0), "Proxy already exists");

        cProxy[_user] = proxy;
        uProxy[proxy] = _user;
        // initialize
        CrossFarmingProxy(proxy).initialize(_user, CAKE, MASTER_CHEF_V2);

        emit ProxyCreated(_user, proxy);
    }
}
