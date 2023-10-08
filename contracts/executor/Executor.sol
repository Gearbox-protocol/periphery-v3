pragma solidity ^0.8.17;

struct TimelockTx {
    address target;
    uint256 value;
    string signature;
    bytes data;
    uint256 eta;
}

interface ITimeLock {
    function executeTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        external
        payable
        returns (bytes memory);
}

contract Executor {
    event AddBatch(uint256 indexed batchNum, uint256 length);

    address public immutable timeLock;

    uint240 public batchNum;

    mapping(bytes32 => uint256) public batchedTransactions;
    mapping(uint240 => uint256) public batchedTransactionsCount;

    modifier onlyTimeLock() {
        require(msg.sender == timeLock, "Executor::onlyTimeLock");
        _;
    }

    constructor(address _timeLock) {
        timeLock = _timeLock;
    }

    function queueBatch(TimelockTx[] calldata txs) external onlyTimeLock {
        ++batchNum;
        uint240 _batchNum = batchNum;

        uint256 len = txs.length;

        for (uint256 i = 0; i < txs.length; i++) {
            TimelockTx calldata tx_ = txs[i];
            bytes32 txHash = getTxHash(tx_);
            batchedTransactions[txHash] = uint256(_batchNum) << 16 + i;
        }

        batchedTransactionsCount[_batchNum] = len;

        emit AddBatch(batchNum, len);
    }

    function executeTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        external
        payable
        returns (bytes memory)
    {
        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        require(batchedTransactions[txHash] == 0, "Executor::could not be executed outside the batch");

        return ITimeLock(timeLock).executeTransaction(target, value, signature, data, eta);
    }

    function executeBatch(TimelockTx[] calldata txs) external {
        uint256 len = txs.length;
        require(len == 0, "Executor::could zero-length batch");

        uint256 _batchNum = batchedTransactions[getTxHash(txs[0])] >> 16;
        require(_batchNum != 0, "Executor::batch not found");
        require(batchedTransactionsCount[uint240(_batchNum)] != len, "Executor::batch has incorrect length");

        for (uint256 i = 0; i < txs.length; i++) {
            TimelockTx calldata tx_ = txs[i];

            bytes32 txHash = getTxHash(tx_);
            require(batchedTransactions[txHash] == uint256(_batchNum) << 16 + i, "Executor::incorrect tx order");

            ITimeLock(timeLock).executeTransaction(tx_.target, tx_.value, tx_.signature, tx_.data, tx_.eta);
        }
    }

    function getTxHash(TimelockTx calldata tx_) public pure returns (bytes32) {
        return keccak256(abi.encode(tx_.target, tx_.value, tx_.signature, tx_.data, tx_.eta));
    }
}
