// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "openzeppelin-contracts/access/Ownable.sol";
import "openzeppelin-contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import "chainlink/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "chainlink/v0.8/VRFConsumerBaseV2.sol";
error Pasanaku_InvalidFrequency();
error Pasanaku_GameNotReady();
error Pasanaku_GameEnded();
error Pasanaku_NotAPlayer();
error Pasanaku_AlreadyDeposited();
error Pasanaku_InvalidAmount();
error Pasanaku_NotAllPlayersHaveDeposited();
error Pasanaku_IsNotPlayerTurnToWidthdraw();

contract Pasanaku is Ownable, VRFConsumerBaseV2 {
    using SafeERC20 for IERC20;

    //TODO: optimize storage by packing variables where possible
    struct Game {
        uint256 startDate; // the time when the game started
        uint256 frequency; //should we set a min and max cap on the frequency to avoid periods being super short or super long?
        uint256 amount; // to be deposited every period
        address token; //should we have a set of allowed tokens?
        uint256 numberOfPlayers; //should we have a min and max cap on the number of players?
        address[] players; // the players of the game. The order of the players is decided by a random number
        bool ready; // true if the random number has been generated
    }

    struct Player {
        bool isPlaying;
        uint256 lastPlayed; // the last time the player deposited
    }

    // represents a turn in the game and the accumulated prize for that turn
    struct Turn {
        address player;
        uint256 prize; // accumulated prize for that turn
    }

    uint16 private constant REQUEST_CONFIRMATIONS = 3; // 3 is the minimum number of request confirmations in most chains
    uint32 private constant CALLBACK_GAS_LIMIT = 1000000; //TODO: adjust based on gas reports on the fallback function
    uint32 private constant NUM_WORDS = 1; // we only need one random number
    uint64 private immutable SUBSCRIPTION_ID;
    VRFCoordinatorV2Interface private immutable COORDINATOR;
    bytes32 private immutable KEY_HASH;

    mapping(uint256 id => Game game) private _games;
    mapping(uint256 gameId => mapping(address playerAddress => Player player))
        private _players; // we also use a mapping to easily query players
    mapping(uint256 gameId => mapping(uint256 turnId => Turn turn))
        private _turns; // Turn of each player

    /**
     * @notice Constructor inherits VRFConsumerBaseV2
     *
     * @param subscriptionId - the subscription ID that this contract uses for funding requests
     * @param vrfCoordinator - coordinator, check https://docs.chain.link/docs/vrf-contracts/#configurations
     * @param keyHash - the gas lane to use, which specifies the maximum gas price to bump to
     */
    constructor(
        uint64 subscriptionId,
        address vrfCoordinator,
        bytes32 keyHash
    ) VRFConsumerBaseV2(vrfCoordinator) {
        SUBSCRIPTION_ID = subscriptionId;
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        KEY_HASH = keyHash;
    }

    // starts a new game
    function start(
        uint256 frequency,
        uint256 amount,
        address[] memory players,
        address token
    ) external returns (uint256 requestId) {
        if (frequency == 0) {
            revert Pasanaku_InvalidFrequency();
        }
        // request a random number - we will use this to decide the order of the players and as a gameId
        requestId = COORDINATOR.requestRandomWords(
            KEY_HASH,
            SUBSCRIPTION_ID,
            REQUEST_CONFIRMATIONS,
            CALLBACK_GAS_LIMIT,
            NUM_WORDS
        );
        // create game
        _games[requestId] = Game(
            block.timestamp,
            frequency,
            amount,
            token,
            players.length,
            players,
            false
        );
        // add players to the game
        for (uint256 i = 0; i < players.length; i++) {
            _players[requestId][players[i]] = Player(true, 0);
        }
    }

    function deposit(uint256 gameId, uint256 amount) external {
        Game storage game = _games[gameId];
        Player storage player = _players[gameId][msg.sender];
        uint256 gameAmount = game.amount; //avoid reading multiple times from storage

        // require the game to be ready
        if (!game.ready) {
            revert Pasanaku_GameNotReady();
        }

        //revert if amount is not equal to the amount set for the game
        if (amount != gameAmount) {
            revert Pasanaku_InvalidAmount();
        }

        //revert if msg.sender is not part of the players array
        if (!_isPlayer(gameId, msg.sender)) {
            revert Pasanaku_NotAPlayer();
        }

        //revert if we are outside the current period
        uint256 currentPeriod = (block.timestamp - game.startDate) /
            game.frequency;

        //TODO: revert if the game has finished(currentPeriod >= amount of players)
        if (currentPeriod >= game.numberOfPlayers) {
            revert Pasanaku_GameEnded();
        }

        //revert if player has already played in the current period
        bool hasPlayedInCurrentPeriod;
        if (player.lastPlayed > 0) {
            uint256 lastPlayedPeriod = (player.lastPlayed - game.startDate) /
                game.frequency;
            hasPlayedInCurrentPeriod = currentPeriod <= lastPlayedPeriod; //lastPlayedPeriod should never be greater than current period, at most equal
        }
        if (hasPlayedInCurrentPeriod) {
            revert Pasanaku_AlreadyDeposited();
        }

        // update state
        player.lastPlayed = block.timestamp;
        _turns[gameId][currentPeriod].prize += gameAmount;

        // transfer tokens
        IERC20(game.token).safeTransferFrom(
            msg.sender,
            address(this),
            gameAmount
        );
    }

    function claimPrize(uint256 gameId, uint256 period) external {
        Game storage game = _games[gameId];

        // require the game to be ready
        if (!game.ready) {
            revert Pasanaku_GameNotReady();
        }

        // require that it is actually the player's turn to withdraw on that period
        if (_turns[gameId][period].player != msg.sender) {
            revert Pasanaku_IsNotPlayerTurnToWidthdraw();
        }

        // require that all players have deposited for the withdraw period
        uint256 prize = _turns[gameId][period].prize;
        if (prize < game.amount * game.numberOfPlayers) {
            //prize should be always equal to game.amount * game.numberOfPlayers if all players have played
            revert Pasanaku_NotAllPlayersHaveDeposited();
        }
        // mark the period as completed by putting the prize back to zero
        _turns[gameId][period].prize = 0;

        // transfer the tokens to the player
        IERC20(game.token).safeTransfer(msg.sender, prize);
    }

    function _isPlayer(
        uint256 game,
        address player
    ) internal view returns (bool isPlaying) {
        isPlaying = _players[game][player].isPlaying;
    }

    /**
     * @notice Callback function used by VRF Coordinator. Here we use the random number to decide the order of the players
     *
     * @param requestId - id of the request
     * @param randomWords - array of random results from VRF Coordinator
     */
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal override {
        uint256 word = randomWords[0];
        Game storage game = _games[requestId];
        uint256 numberOfPlayers = game.numberOfPlayers;
        address[] memory players = game.players;

        // create en empty array with the turn of the players
        // TODO: maybe using push is more gas efficient??
        uint256[] memory playerIndexes = new uint256[](numberOfPlayers);
        for (uint i = 0; i < numberOfPlayers; i++) {
            playerIndexes[i] = i;
        }

        // Fisher-Yates shuffle
        for (uint256 i = numberOfPlayers - 1; i > 0; i--) {
            uint256 j = word % (i + 1);
            word /= 10;
            // Swap playerIndexes[i] and playerIndexes[j]
            (playerIndexes[i], playerIndexes[j]) = (
                playerIndexes[j],
                playerIndexes[i]
            );
        }

        // Set the turn order in the _turns mapping
        for (uint256 i = 0; i < numberOfPlayers; i++) {
            _turns[requestId][i] = Turn(players[playerIndexes[i]], 0); //initial prize for all periods is zero since there are no deposits
        }

        // Now we are ready to start the game
        game.ready = true;
    }

    function getGame(uint256 gameId) external view returns (Game memory game) {
        return _games[gameId];
    }

    function getPlayer(
        uint256 gameId,
        address player
    ) external view returns (Player memory) {
        return _players[gameId][player];
    }
}
