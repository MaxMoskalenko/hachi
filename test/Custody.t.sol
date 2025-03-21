// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "lib/forge-std/src/Test.sol";
import {Custody} from "../src/Custody.sol";
import {TicTacToe} from "../src/adjudicators/TicTacToe.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import "../src/interfaces/Types.sol";

contract CustodyTest is Test {
    Custody public custody;
    TicTacToe public adjudicator;
    MockERC20 public token;

    // Test addresses
    address public host;
    address public guest;

    // Private keys for signing
    uint256 private hostKey = 0x3c6c54cc258103d1d9e51383adf05ff1b47e76386c17c3a8342021715bf712c3; // 0xDc070f75a3bEf9D39056998D6Be38188142165dB
    uint256 private guestKey = 0xfff557ae11ab16949276c1cbe10899606e916022968bf4889a9cafb41c1b2c87; // 0x339C7D26152Bdf518fC152b548c52c5c80cCaC66

    // Channel constants
    uint64 private constant CHANNEL_NONCE = 1;
    uint256 private constant INITIAL_DEPOSIT = 100 * 10 ** 18;

    function setUp() public {
        // Deploy contracts
        custody = new Custody();
        adjudicator = new TicTacToe();
        token = new MockERC20("Test Token", "TST", 18);

        // Set up test accounts
        host = vm.addr(hostKey);
        guest = vm.addr(guestKey);
        vm.label(host, "Host");
        vm.label(guest, "Guest");

        // Mint and approve tokens
        token.mint(host, INITIAL_DEPOSIT);
        token.mint(guest, INITIAL_DEPOSIT);

        vm.prank(host);
        token.approve(address(custody), INITIAL_DEPOSIT);

        vm.prank(guest);
        token.approve(address(custody), INITIAL_DEPOSIT);
    }

    function createTestChannel() public view returns (Channel memory) {
        address[] memory participants = new address[](2);
        participants[0] = host;
        participants[1] = guest;

        return Channel({
            participants: participants,
            adjudicator: address(adjudicator),
            nonce: CHANNEL_NONCE
        });
    }

    function test_OpenChannelSuccess() public {
        Channel memory channel = createTestChannel();

        // Host opens channel
        vm.prank(host);
        Asset memory hostDeposit = Asset({
            token: address(token),
            amount: INITIAL_DEPOSIT / 2
        });
        bytes32 channelId = custody.open(channel, hostDeposit);

        // Guest joins channel
        vm.prank(guest);
        Asset memory guestDeposit = Asset({
            token: address(token),
            amount: INITIAL_DEPOSIT / 2
        });
        custody.open(channel, guestDeposit);

        // Verify deposits
        assertEq(token.balanceOf(address(custody)), INITIAL_DEPOSIT);
        assertEq(token.balanceOf(host), INITIAL_DEPOSIT / 2);
        assertEq(token.balanceOf(guest), INITIAL_DEPOSIT / 2);
    }

    function test_OpenChannelInvalidParticipants() public {
        // Create channel with wrong number of participants
        address[] memory participants = new address[](1);
        participants[0] = host;

        Channel memory channel = Channel({
            participants: participants,
            adjudicator: address(adjudicator),
            nonce: CHANNEL_NONCE
        });

        Asset memory deposit = Asset({
            token: address(token),
            amount: INITIAL_DEPOSIT / 2
        });

        // Should revert with InvalidParticipants
        vm.prank(host);
        vm.expectRevert(Custody.InvalidParticipants.selector);
        custody.open(channel, deposit);
    }

    function test_OpenChannelInvalidCaller() public {
        Channel memory channel = createTestChannel();
        Asset memory deposit = Asset({
            token: address(token),
            amount: INITIAL_DEPOSIT / 2
        });

        // Try to open channel from non-participant address
        address randomUser = address(0x999);
        vm.prank(randomUser);
        vm.expectRevert(Custody.InvalidCaller.selector);
        custody.open(channel, deposit);
    }

    function test_CloseChannelSuccess() public {
        Channel memory channel = createTestChannel();

        // First open the channel
        vm.prank(host);
        Asset memory hostDeposit = Asset({
            token: address(token),
            amount: INITIAL_DEPOSIT / 2
        });
        bytes32 channelId = custody.open(channel, hostDeposit);

        vm.prank(guest);
        Asset memory guestDeposit = Asset({
            token: address(token),
            amount: INITIAL_DEPOSIT / 2
        });
        custody.open(channel, guestDeposit);

        // Create final game state (a draw scenario)
        TicTacToe.GameState memory gameState = TicTacToe.GameState({
            version: 1,
            board: [uint8(2), 1, 2, 1, 2, 1, 1, 2, 1], // Draw board
            turn: 2,
            winner: 3 // Draw
        });

        // Create signed state from both participants
        bytes32 gameStateHash = keccak256(abi.encode(gameState));
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(hostKey, gameStateHash);
        Signature memory gameStateSignature = Signature({v: v, r: r, s: s});

        // Prepare state data
        TicTacToe.SignedGameState memory signedState = TicTacToe.SignedGameState({
            state: gameState,
            signature: gameStateSignature
        });

        State memory finalState;
        finalState.data = abi.encode(signedState);

        // On draft everyone 
        finalState.outcome = new Asset[](2);
        finalState.outcome[0] = hostDeposit;
        finalState.outcome[1] = guestDeposit;

        bytes32 finalStateHash = keccak256(abi.encode(finalState));

        Signature[2] memory signatures;
        (v, r, s) = vm.sign(hostKey, finalStateHash);
        signatures[0] = Signature({v: v, r: r, s: s});

        (v, r, s) = vm.sign(guestKey, finalStateHash);
        signatures[1] = Signature({v: v, r: r, s: s});

        // Close the channel
        vm.prank(host);
        custody.close(channelId, finalState, signatures);

        // Verify final balances (should be equal split for draw)
        assertEq(token.balanceOf(host), INITIAL_DEPOSIT / 2);
        assertEq(token.balanceOf(guest), INITIAL_DEPOSIT / 2);
        assertEq(token.balanceOf(address(custody)), 0);
    }

    function test_CloseChannelInvalidStatus() public {
        Channel memory channel = createTestChannel();
        bytes32 channelId = keccak256(abi.encode(channel));

        // Try to close a non-existent channel
        TicTacToe.GameState memory gameState = TicTacToe.GameState({
            version: 1,
            board: [uint8(1), 2, 1, 2, 1, 2, 2, 1, 2],
            turn: 2,
            winner: 3
        });

        bytes32 stateHash = keccak256(abi.encode(gameState));
        
        Signature[2] memory signatures;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(hostKey, stateHash);
        signatures[0] = Signature({v: v, r: r, s: s});
        
        (v, r, s) = vm.sign(guestKey, stateHash);
        signatures[1] = Signature({v: v, r: r, s: s});

        TicTacToe.SignedGameState memory signedState = TicTacToe.SignedGameState({
            state: gameState,
            signature: signatures[0]
        });

        State memory finalState;
        finalState.data = abi.encode(signedState);
        finalState.outcome = new Asset[](2);

        vm.expectRevert(Custody.InvalidStatus.selector);
        custody.close(channelId, finalState, signatures);
    }

    function test_CloseChannelInvalidSignature() public {
        Channel memory channel = createTestChannel();

        // Open channel
        vm.prank(host);
        Asset memory hostDeposit = Asset({
            token: address(token),
            amount: INITIAL_DEPOSIT / 2
        });
        bytes32 channelId = custody.open(channel, hostDeposit);

        vm.prank(guest);
        Asset memory guestDeposit = Asset({
            token: address(token),
            amount: INITIAL_DEPOSIT / 2
        });
        custody.open(channel, guestDeposit);

        // Create game state
        TicTacToe.GameState memory gameState = TicTacToe.GameState({
            version: 1,
            board: [uint8(1), 2, 1, 2, 1, 2, 2, 1, 2],
            turn: 2,
            winner: 3
        });

        bytes32 stateHash = keccak256(abi.encode(gameState));
        
        // Create invalid signatures
        Signature[2] memory signatures;
        uint256 wrongKey = 0x999;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, stateHash);
        signatures[0] = Signature({v: v, r: r, s: s});
        signatures[1] = signatures[0];

        TicTacToe.SignedGameState memory signedState = TicTacToe.SignedGameState({
            state: gameState,
            signature: signatures[0]
        });

        State memory finalState;
        finalState.data = abi.encode(signedState);
        finalState.outcome = new Asset[](2);

        vm.expectRevert(Custody.InvalidSignature.selector);
        custody.close(channelId, finalState, signatures);
    }
}
