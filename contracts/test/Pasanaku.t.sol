// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Pasanaku.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {VRFCoordinatorV2Mock} from "chainlink/v0.8/mocks/VRFCoordinatorV2Mock.sol";

contract PasanakuTest is Test {
    address private constant PLAYER_1 = address(1);
    address private constant PLAYER_2 = address(2);
    address private constant PLAYER_3 = address(3);
    address private constant PLAYER_4 = address(4);
    address private constant PLAYER_5 = address(5);
    address private constant NON_PLAYER_1 = address(6);
    address private constant NON_PLAYER_2 = address(7);
    address private constant NON_PLAYER_3 = address(8);
    address private constant NON_PLAYER_4 = address(9);
    address private constant NON_PLAYER_5 = address(10);

    bytes32 private constant KEY_HASH = 0xd89b2bf150e3b9e13446986e571fb9cab24b13cea0a43ea20a6049a85cc807cc; //Doesn't really matter

    Pasanaku public pasanaku;
    address[] public players;
    address[] public non_players;
    VRFCoordinatorV2Mock public vrfCoordinatorV2Mock;
    uint64 public vrfCoordinatorV2SubscriptionId;
    uint256 ONE_MONTH_INTERVAL = 30 days;

    ERC20 public erc20Contract;

    event RandomWordsRequested(
        bytes32 indexed keyHash,
        uint256 requestId,
        uint256 preSeed,
        uint64 indexed subId,
        uint16 minimumRequestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords,
        address indexed sender
    );
    event GameStarted(
        uint256 indexed gameId, uint256 indexed frequency, address indexed token, uint256 amount, address[] players
    );
    event PlayerDeposited(uint256 indexed gameId, address indexed player, uint256 indexed period, uint256 amount);

    function setUp() public {
        erc20Contract = new ERC20("Mck", "Mock");

        // Values taken from this repo https://github.com/PatrickAlphaC/foundry-smart-contract-lottery-f23/blob/main/script/HelperConfig.s.sol#LL78C9-L79C35
        // Does it really matter?
        uint96 baseFee = 0.25 ether;
        uint96 gasPriceLink = 1e9;

        vrfCoordinatorV2Mock = new VRFCoordinatorV2Mock(baseFee, gasPriceLink);
        vrfCoordinatorV2SubscriptionId = vrfCoordinatorV2Mock.createSubscription();
        vrfCoordinatorV2Mock.fundSubscription(vrfCoordinatorV2SubscriptionId, 3e18);

        pasanaku = new Pasanaku(
            vrfCoordinatorV2SubscriptionId,
            address(vrfCoordinatorV2Mock),
            KEY_HASH
        );

        vrfCoordinatorV2Mock.addConsumer(vrfCoordinatorV2SubscriptionId, address(pasanaku));

        players = [PLAYER_1, PLAYER_2, PLAYER_3, PLAYER_4, PLAYER_5];
        non_players = [NON_PLAYER_1, NON_PLAYER_2, NON_PLAYER_3, NON_PLAYER_4, NON_PLAYER_5];
    }

    function test_start_CreatesANewGame() public {
        uint256 gameId = pasanaku.start(ONE_MONTH_INTERVAL, 1e6, players, address(erc20Contract));

        Pasanaku.Game memory game = pasanaku.getGame(gameId);
        assertEq(game.startDate, block.timestamp);
    }

    function test_start_EmitsGameStartedEvent() public {
        vm.expectEmit(true, true, true, true);
        emit GameStarted(1, ONE_MONTH_INTERVAL, address(erc20Contract), 1e6, players);
        pasanaku.start(ONE_MONTH_INTERVAL, 1e6, players, address(erc20Contract));
    }

    function test_start_AddsRigthNumberOfPlayers() public {
        uint256 gameId = pasanaku.start(ONE_MONTH_INTERVAL, 1e6, players, address(erc20Contract));

        Pasanaku.Game memory game = pasanaku.getGame(gameId);
        assertEq(game.players.length, players.length);
    }

    function test_start_RevertIfFrequencyIsZero() public {
        vm.expectRevert(Pasanaku_InvalidFrequency.selector);
        pasanaku.start(0, 1e6, players, address(erc20Contract));
    }

    function test_start_GameIsNotReady() public {
        uint256 gameId = pasanaku.start(ONE_MONTH_INTERVAL, 1e6, players, address(erc20Contract));

        Pasanaku.Game memory game = pasanaku.getGame(gameId);
        assertEq(game.ready, false);
    }

    function test_start_requestsRandomWords() public {
        vm.expectEmit(true, true, true, false);
        // Emit the event with the right values on the indexed parameters, others are set to zero
        emit RandomWordsRequested(KEY_HASH, 0, 0, 1, 0, 0, 0, address(pasanaku));

        pasanaku.start(ONE_MONTH_INTERVAL, 1e6, players, address(erc20Contract));
    }

    function test_deposit_UpdatesLastPlayed() public {
        uint256 amount = 1 ether;
        // start game and fulfill random words
        uint256 gameId = pasanaku.start(ONE_MONTH_INTERVAL, amount, players, address(erc20Contract));
        vrfCoordinatorV2Mock.fulfillRandomWords(gameId, address(pasanaku));

        // mint `amount`number of tokens to player 1
        deal(address(erc20Contract), PLAYER_1, amount);

        // deposit `amount` number of tokens to the game
        vm.startPrank(PLAYER_1);
        erc20Contract.approve(address(pasanaku), amount);
        pasanaku.deposit(gameId, amount);

        // check that the last played is updated to block.timestamp
        assertEq(pasanaku.getPlayer(gameId, PLAYER_1).lastPlayed, block.timestamp);
    }

    function test_deposit_IncreasesPrize() public {
        uint256 amount = 1 ether;
        // start game and fulfill random words
        uint256 gameId = pasanaku.start(ONE_MONTH_INTERVAL, amount, players, address(erc20Contract));
        vrfCoordinatorV2Mock.fulfillRandomWords(gameId, address(pasanaku));

        // mint `amount`number of tokens to players 1 and 2
        deal(address(erc20Contract), PLAYER_1, amount);
        deal(address(erc20Contract), PLAYER_2, amount);

        // deposit twice with different players
        vm.startPrank(PLAYER_1);
        erc20Contract.approve(address(pasanaku), amount);
        pasanaku.deposit(gameId, amount);
        vm.stopPrank();

        vm.startPrank(PLAYER_2);
        erc20Contract.approve(address(pasanaku), amount);
        pasanaku.deposit(gameId, amount);

        // check that the prize for the current period has increased
        uint256 period = 0;
        assertEq(pasanaku.getPrize(gameId, period), amount * 2);
    }

    function test_deposit_EmitsDepositEvent() public {
        uint256 amount = 1 ether;
        // start game and fulfill random words
        uint256 gameId = pasanaku.start(ONE_MONTH_INTERVAL, amount, players, address(erc20Contract));
        vrfCoordinatorV2Mock.fulfillRandomWords(gameId, address(pasanaku));

        // mint `amount`number of tokens to player 1
        deal(address(erc20Contract), PLAYER_1, amount);

        // deposit `amount` number of tokens to the game and check that the right event is emitted
        vm.startPrank(PLAYER_1);
        erc20Contract.approve(address(pasanaku), amount);
        vm.expectEmit(true, true, true, true);
        emit PlayerDeposited(gameId, PLAYER_1, 0, amount);
        pasanaku.deposit(gameId, amount);
    }

    // function test_CanDepositWhenGameIsReady() public {
    //     uint96 amount = 1 ether;
    //     uint256 gameId = pasanaku.start(ONE_MONTH_INTERVAL, amount, players, address(erc20Contract));
    //     hoax(players[0], 1 ether);
    //     assertEq(pasanaku.getGame(gameId).ready, false);
    //     vrfCoordinatorV2Mock.fulfillRandomWords(gameId, address(pasanaku));
    //     assertEq(pasanaku.getGame(gameId).ready, true);
    //     erc20Contract.mint(players[0], 10 ether);

    //     vm.prank(players[0]);
    //     erc20Contract.approve(address(pasanaku), 10 ether);

    //     vm.prank(players[0]);
    //     pasanaku.deposit(gameId, amount);
    // }

    // function test_RevertWhen_GameNotReady() public {
    //     address token = address(1);
    //     uint96 amount = 1 ether;
    //     uint256 gameId = pasanaku.start(ONE_MONTH_INTERVAL, amount, players, token);
    //     hoax(msg.sender, 1 ether);
    //     assertEq(pasanaku.getGame(gameId).ready, false);
    //     vm.expectRevert(Pasanaku_GameNotReady.selector);
    //     vm.prank(players[0]);
    //     pasanaku.deposit(gameId, amount);
    // }

    // function test_RevertWhen_InvalidAmount() public {
    //     address token = address(1);
    //     uint96 amount = 1 ether;
    //     uint256 gameId = pasanaku.start(ONE_MONTH_INTERVAL, amount, players, token);
    //     hoax(players[0], 1 ether);
    //     vrfCoordinatorV2Mock.fulfillRandomWords(gameId, address(pasanaku));
    //     assertEq(pasanaku.getGame(gameId).ready, true);
    //     vm.expectRevert(Pasanaku_InvalidAmount.selector);
    //     vm.prank(players[0]);
    //     pasanaku.deposit(gameId, amount + 1);
    // }

    // function test_RevertWhen_NotAPlayer() public {
    //     address token = address(1);
    //     uint96 amount = 1 ether;
    //     uint256 gameId = pasanaku.start(ONE_MONTH_INTERVAL, amount, players, token);
    //     hoax(non_players[0], 1 ether);
    //     vrfCoordinatorV2Mock.fulfillRandomWords(gameId, address(pasanaku));
    //     assertEq(pasanaku.getGame(gameId).ready, true);
    //     vm.expectRevert(Pasanaku_NotAPlayer.selector);
    //     vm.prank(non_players[0]);
    //     pasanaku.deposit(gameId, amount);
    // }

    // function test_RevertWhen_GameEnded() public {
    //     uint96 amount = 1 ether;
    //     uint256 gameId = pasanaku.start(ONE_MONTH_INTERVAL, amount, players, address(erc20Contract));
    //     hoax(players[0], 1 ether);
    //     vrfCoordinatorV2Mock.fulfillRandomWords(gameId, address(pasanaku));
    //     assertEq(pasanaku.getGame(gameId).ready, true);

    //     vm.startPrank(players[0]);
    //     erc20Contract.approve(address(pasanaku), 10 ether);

    //     vm.expectRevert(Pasanaku_GameEnded.selector);
    //     vm.warp(block.timestamp + ONE_MONTH_INTERVAL * players.length);
    //     pasanaku.deposit(gameId, amount);
    // }

    // function test_RevertWhen_AlreadyDeposited() public {
    //     uint96 amount = 1 ether;
    //     uint256 gameId = pasanaku.start(ONE_MONTH_INTERVAL, amount, players, address(erc20Contract));
    //     hoax(players[0], 1 ether);
    //     vrfCoordinatorV2Mock.fulfillRandomWords(gameId, address(pasanaku));
    //     assertEq(pasanaku.getGame(gameId).ready, true);
    //     erc20Contract.mint(players[0], 10 ether);

    //     vm.startPrank(players[0]);
    //     erc20Contract.approve(address(pasanaku), 10 ether);

    //     pasanaku.deposit(gameId, amount);

    //     vm.expectRevert(Pasanaku_AlreadyDepositedInCurrentPeriod.selector);
    //     pasanaku.deposit(gameId, amount);
    // }
}
