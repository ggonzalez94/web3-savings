// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Pasanaku.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {VRFCoordinatorV2Mock} from "chainlink/v0.8/mocks/VRFCoordinatorV2Mock.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

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

    bytes32 private constant KEY_HASH =
        0xd89b2bf150e3b9e13446986e571fb9cab24b13cea0a43ea20a6049a85cc807cc; //Doesn't really matter

    Pasanaku public pasanaku;
    address[] public players;
    address[] public non_players;
    VRFCoordinatorV2Mock public vrfCoordinatorV2Mock;
    uint64 public vrfCoordinatorV2SubscriptionId;
    uint256 ONE_MONTH_INTERVAL = 30 days;

    ERC20Mock public erc20Contract;

    function setUp() public {
        erc20Contract = new ERC20Mock("Mck", "Mock");

        // Values taken from this repo https://github.com/PatrickAlphaC/foundry-smart-contract-lottery-f23/blob/main/script/HelperConfig.s.sol#LL78C9-L79C35
        // Does it really matter?
        uint96 baseFee = 0.25 ether;
        uint96 gasPriceLink = 1e9;

        vrfCoordinatorV2Mock = new VRFCoordinatorV2Mock(baseFee, gasPriceLink);
        vrfCoordinatorV2SubscriptionId = vrfCoordinatorV2Mock
            .createSubscription();
        vrfCoordinatorV2Mock.fundSubscription(
            vrfCoordinatorV2SubscriptionId,
            3e18
        );

        pasanaku = new Pasanaku(
            vrfCoordinatorV2SubscriptionId,
            address(vrfCoordinatorV2Mock),
            KEY_HASH
        );

        vrfCoordinatorV2Mock.addConsumer(
            vrfCoordinatorV2SubscriptionId,
            address(pasanaku)
        );

        players = [PLAYER_1, PLAYER_2, PLAYER_3, PLAYER_4, PLAYER_5];
        non_players = [
            NON_PLAYER_1,
            NON_PLAYER_2,
            NON_PLAYER_3,
            NON_PLAYER_4,
            NON_PLAYER_5
        ];
    }

    function testFuzz_StartGame(uint256 frequency, uint96 amount) public {
        if (frequency == 0) {
            vm.expectRevert(Pasanaku_InvalidFrequency.selector);
        }
        uint256 gameId = pasanaku.start(
            frequency,
            amount,
            players,
            address(erc20Contract)
        );
        if (frequency == 0) {
            return;
        }
        assertEq(pasanaku.getGame(gameId).startDate, block.timestamp);
        assertEq(pasanaku.getGame(gameId).frequency, frequency);
        assertEq(pasanaku.getGame(gameId).amount, amount);
        assertEq(pasanaku.getGame(gameId).token, address(erc20Contract));
        assertEq(pasanaku.getGame(gameId).ready, false);
        for (uint256 i = 0; i < players.length; i++) {
            assertEq(pasanaku.getPlayer(gameId, players[i]).isPlaying, true);
            assertEq(pasanaku.getPlayer(gameId, players[i]).lastPlayed, 0);
        }
        for (uint256 i = 0; i < non_players.length; i++) {
            assertEq(
                pasanaku.getPlayer(gameId, non_players[i]).isPlaying,
                false
            );
            assertEq(pasanaku.getPlayer(gameId, non_players[i]).lastPlayed, 0);
        }
    }

    function test_CanDepositWhenGameIsReady() public {
        uint96 amount = 1 ether;
        uint256 gameId = pasanaku.start(
            ONE_MONTH_INTERVAL,
            amount,
            players,
            address(erc20Contract)
        );
        hoax(players[0], 1 ether);
        assertEq(pasanaku.getGame(gameId).ready, false);
        vrfCoordinatorV2Mock.fulfillRandomWords(gameId, address(pasanaku));
        assertEq(pasanaku.getGame(gameId).ready, true);
        erc20Contract.mint(players[0], 10 ether);

        vm.prank(players[0]);
        erc20Contract.approve(address(pasanaku), 10 ether);

        vm.prank(players[0]);
        pasanaku.deposit(gameId, amount);
    }

    function test_RevertWhen_GameNotReady() public {
        address token = address(1);
        uint96 amount = 1 ether;
        uint256 gameId = pasanaku.start(
            ONE_MONTH_INTERVAL,
            amount,
            players,
            token
        );
        hoax(msg.sender, 1 ether);
        assertEq(pasanaku.getGame(gameId).ready, false);
        vm.expectRevert(Pasanaku_GameNotReady.selector);
        vm.prank(players[0]);
        pasanaku.deposit(gameId, amount);
    }

    function test_RevertWhen_InvalidAmount() public {
        address token = address(1);
        uint96 amount = 1 ether;
        uint256 gameId = pasanaku.start(
            ONE_MONTH_INTERVAL,
            amount,
            players,
            token
        );
        hoax(players[0], 1 ether);
        vrfCoordinatorV2Mock.fulfillRandomWords(gameId, address(pasanaku));
        assertEq(pasanaku.getGame(gameId).ready, true);
        vm.expectRevert(Pasanaku_InvalidAmount.selector);
        vm.prank(players[0]);
        pasanaku.deposit(gameId, amount + 1);
    }

    function test_RevertWhen_NotAPlayer() public {
        address token = address(1);
        uint96 amount = 1 ether;
        uint256 gameId = pasanaku.start(
            ONE_MONTH_INTERVAL,
            amount,
            players,
            token
        );
        hoax(non_players[0], 1 ether);
        vrfCoordinatorV2Mock.fulfillRandomWords(gameId, address(pasanaku));
        assertEq(pasanaku.getGame(gameId).ready, true);
        vm.expectRevert(Pasanaku_NotAPlayer.selector);
        vm.prank(non_players[0]);
        pasanaku.deposit(gameId, amount);
    }

    function test_RevertWhen_GameEnded() public {
        uint96 amount = 1 ether;
        uint256 gameId = pasanaku.start(
            ONE_MONTH_INTERVAL,
            amount,
            players,
            address(erc20Contract)
        );
        hoax(players[0], 1 ether);
        vrfCoordinatorV2Mock.fulfillRandomWords(gameId, address(pasanaku));
        assertEq(pasanaku.getGame(gameId).ready, true);

        vm.startPrank(players[0]);
        erc20Contract.approve(address(pasanaku), 10 ether);

        vm.expectRevert(Pasanaku_GameEnded.selector);
        vm.warp(block.timestamp + ONE_MONTH_INTERVAL * players.length);
        pasanaku.deposit(gameId, amount);
    }

    function test_RevertWhen_AlreadyDeposited() public {
        uint96 amount = 1 ether;
        uint256 gameId = pasanaku.start(
            ONE_MONTH_INTERVAL,
            amount,
            players,
            address(erc20Contract)
        );
        hoax(players[0], 1 ether);
        vrfCoordinatorV2Mock.fulfillRandomWords(gameId, address(pasanaku));
        assertEq(pasanaku.getGame(gameId).ready, true);
        erc20Contract.mint(players[0], 10 ether);

        vm.startPrank(players[0]);
        erc20Contract.approve(address(pasanaku), 10 ether);

        pasanaku.deposit(gameId, amount);

        vm.expectRevert(Pasanaku_AlreadyDepositedInCurrentPeriod.selector);
        pasanaku.deposit(gameId, amount);
    }
}
