// SPDX-License-Identifier: MIT 
pragma solidity 0.8.19; 

import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {VRFCoordinatorV2Interface} from "chainlink/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import {VRFConsumerBaseV2} from "chainlink/v0.8/VRFConsumerBaseV2.sol";

/// @title Pasanaku Contract
/// Pasanaku is a traditional community savings system, particularly popular in Bolivia and Peru operating on the principle of rotating credit and savings.
/// Members contribute a set amount of money at regular intervals, creating a fund which is given as a lump sum to one member per cycle.
/// This blockchain-based version of Pasanaku ensures a transparent, secure, and efficient distribution of funds among participants, while respecting the tradition's mutual support ethos.
/// @notice This contract represents a game where players deposit a set amount in regular intervals. At the end of each period, one of the players gets to claim the accumulated prize.
contract Pasanaku is Ownable, VRFConsumerBaseV2 {
    using SafeERC20 for IERC20;

    ///////////////////
    // Types
    ///////////////////
    struct Game {
        uint256 startDate; // the time when the game started
        uint256 frequency; // TODO: Set max frequency?
        uint256 amount; // to be deposited every period
        address token;
        bool ready; // true if the random number has been generated
        address[] players; // the players of the game. The order of the players is decided by a random number
    }

    struct Player {
        bool isPlaying;
        uint256 lastPlayed; // the last time the player deposited
    }

    // represents a turn to withdraw in the game and the accumulated prize for that turn
    struct Turn {
        address player;
        uint256 prize; // accumulated prize for that turn
    }

    ///////////////////
    // State Variables
    ///////////////////
    uint16 private constant REQUEST_CONFIRMATIONS = 3; // 3 is the minimum number of request confirmations in most chains
    uint32 private constant CALLBACK_GAS_LIMIT = 1000000; //TODO: adjust based on gas reports on the fallback function
    uint32 private constant NUM_WORDS = 1; // we only need one random number
    uint256 private constant FEE = 2; //2% TODO: Decide on the right protocol fee
    uint64 private immutable SUBSCRIPTION_ID;
    VRFCoordinatorV2Interface private immutable COORDINATOR;
    bytes32 private immutable KEY_HASH; // Gas Lane

    mapping(uint256 id => Game game) private _games;
    mapping(uint256 gameId => mapping(address playerAddress => Player player)) private _players;
    mapping(uint256 gameId => mapping(uint256 turnId => Turn turn)) private _turns; // Turn for claming the prize of each player
    mapping(address token => uint256 balance) private _revenue; // revenue balance for each token

    ///////////////////
    // Events
    ///////////////////
    event GameStarted(
        uint256 indexed gameId, uint256 indexed frequency, address indexed token, uint256 amount, address[] players
    );
    event PlayerDeposited(uint256 indexed gameId, address indexed player, uint256 indexed period, uint256 amount);
    event PrizeClaimed(uint256 indexed gameId, address indexed player, uint256 indexed period, uint256 amount);

    ///////////////////
    // Custom Errors
    ///////////////////
    error Pasanaku__InvalidFrequency();
    error Pasanaku__GameNotReady();
    error Pasanaku__GameEnded();
    error Pasanaku__NotAPlayer();
    error Pasanaku__AlreadyDepositedInCurrentPeriod();
    error Pasanaku__InvalidAmount();
    error Pasanaku__NotAllPlayersHaveDeposited();
    error Pasanaku__IsNotPlayerTurnToWidthdraw();

    ///////////////////
    // Functions
    ///////////////////

    /**
     * @notice Constructor inherits VRFConsumerBaseV2
     *
     * @param subscriptionId - the subscription ID that this contract uses for funding requests
     * @param vrfCoordinator - coordinator, check https://docs.chain.link/docs/vrf-contracts/#configurations
     * @param keyHash - the gas lane to use, which specifies the maximum gas price to bump to
     */
    constructor(uint64 subscriptionId, address vrfCoordinator, bytes32 keyHash) VRFConsumerBaseV2(vrfCoordinator) {
        SUBSCRIPTION_ID = subscriptionId;
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        KEY_HASH = keyHash;
    }

    ///////////////////////
    // External Functions
    ///////////////////////

    /// @notice Starts a new game with the given parameters
    /// @dev When the game starts it requests a random number from the Chainlink VRF
    /// @dev The game starts as not ready, and it will be ready once the random number is generated. The Chainlink VRF will call the `fulfillRandomness` function
    /// @param frequency The time period in which each player has to make their deposit
    /// @param amount The amount that each player has to deposit every period
    /// @param players The addresses of the players
    /// @param token The token to be used for deposits
    /// @return gameId The id of the game
    function start(uint256 frequency, uint256 amount, address[] calldata players, address token)
        external
        returns (uint256 gameId)
    {
        if (frequency == 0) {
            revert Pasanaku__InvalidFrequency();
        }
        // Request a random number - we will use this to decide the order of the players and as a gameId
        gameId = COORDINATOR.requestRandomWords(
            KEY_HASH, SUBSCRIPTION_ID, REQUEST_CONFIRMATIONS, CALLBACK_GAS_LIMIT, NUM_WORDS
        );
        // Create game
        _games[gameId] = Game({
            startDate: block.timestamp,
            frequency: frequency,
            amount: amount,
            token: token,
            ready: false,
            players: players
        });
        // Add players to the game
        for (uint256 i = 0; i < players.length; i++) {
            _players[gameId][players[i]] = Player(true, 0);
        }
        emit GameStarted(gameId, frequency, token, amount, players);
    }

    /// @notice Allows a player to make their deposit for the current period. Only registered players to the game can make deposits and only once per period
    /// @notice The player must approve the contract to spend the amount of the deposit before calling this function
    /// @param gameId The id of the game
    /// @param amount The amount to deposit, which must be equal to the game amount
    function deposit(uint256 gameId, uint256 amount) external {
        Game storage game = _games[gameId];
        Player storage player = _players[gameId][msg.sender];
        uint256 gameAmount = game.amount;

        // Require the game to be ready
        if (!game.ready) {
            revert Pasanaku__GameNotReady();
        }

        // Revert if amount is not equal to the amount set for the game
        if (amount != gameAmount) {
            revert Pasanaku__InvalidAmount();
        }

        // Revert if msg.sender is not part of the players array
        if (!player.isPlaying) {
            revert Pasanaku__NotAPlayer();
        }

        uint256 startDate = game.startDate;
        uint256 frequency = game.frequency;
        uint256 currentPeriod = (block.timestamp - startDate) / frequency;

        // Revert if the game has ended
        if (currentPeriod >= game.players.length) {
            revert Pasanaku__GameEnded();
        }

        // Revert if player has already played in the current period
        bool hasPlayedInCurrentPeriod;
        uint256 lastPlayed = player.lastPlayed;
        if (lastPlayed > 0) {
            uint256 lastPlayedPeriod = (lastPlayed - startDate) / frequency;
            hasPlayedInCurrentPeriod = currentPeriod <= lastPlayedPeriod; //lastPlayedPeriod should never be greater than current period, at most equal
        }
        if (hasPlayedInCurrentPeriod) {
            revert Pasanaku__AlreadyDepositedInCurrentPeriod();
        }

        // Update state
        player.lastPlayed = block.timestamp;
        _turns[gameId][currentPeriod].prize += gameAmount;

        // Transfer tokens
        IERC20(game.token).safeTransferFrom(msg.sender, address(this), gameAmount);

        // Emit event
        emit PlayerDeposited(gameId, msg.sender, currentPeriod, amount);
    }

    /// @notice Allows the player whose turn it is to claim the prize for a period
    /// @dev You can claim prizes for previous periods as long as all players have deposited for that period
    /// @param gameId The id of the game
    /// @param period The period for which the player is claiming the prize
    function claimPrize(uint256 gameId, uint256 period) external {
        Game storage game = _games[gameId];
        address tokenAddress = game.token;

        // Require that it is actually the player's turn to withdraw on that period
        if (_turns[gameId][period].player != msg.sender) {
            revert Pasanaku__IsNotPlayerTurnToWidthdraw();
        }

        // Require that all players have deposited for the withdraw period
        uint256 prize = _turns[gameId][period].prize;
        if (prize < game.amount * game.players.length) {
            // Prize should be always equal to game.amount * game.players.length if all players have played
            revert Pasanaku__NotAllPlayersHaveDeposited();
        }
        // Mark the period as completed by putting the prize back to zero
        _turns[gameId][period].prize = 0;

        // Reserve a FEE % of the prize for the protocol
        uint256 protocolFee = (prize * FEE) / 100;
        prize -= protocolFee;

        // Increase the balance for the fee
        _revenue[tokenAddress] += protocolFee;

        // Transfer the tokens to the player
        IERC20(tokenAddress).safeTransfer(msg.sender, prize);

        // Emit event
        emit PrizeClaimed(gameId, msg.sender, period, prize);
    }

    /// @notice Allows the owner to withdraw the revenue for a list of tokens
    /// @param tokens The tokens for which to withdraw the revenue
    function withdrawRevenue(address[] calldata tokens) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            // Get the accumulated balance for the token
            uint256 balance = _revenue[tokens[i]];
            // Reset the balance
            _revenue[tokens[i]] = 0;

            // Transfer the tokens to the owner
            IERC20 token = IERC20(tokens[i]);
            token.safeTransfer(owner(), balance);
        }
    }

    /// @notice Fetches the details of a game
    /// @param gameId The id of the game
    /// @return A Game struct with all the details of the game
    function getGame(uint256 gameId) external view returns (Game memory) {
        return _games[gameId];
    }

    /// @notice Fetches the details of a player in a game
    /// @param gameId The id of the game
    /// @param player The address of the player
    /// @return A Player struct with the details of the player in the game
    function getPlayer(uint256 gameId, address player) external view returns (Player memory) {
        return _players[gameId][player];
    }

    /// @notice Fetches the prize for a given period in a game
    /// @param gameId The id of the game
    /// @param period The period for which to fetch the prize. Periods start at 0
    /// @return The prize for the given period in the game
    function getPrize(uint256 gameId, uint256 period) external view returns (uint256) {
        return _turns[gameId][period].prize;
    }

    /// @notice Fetches the winner for a given period in a game
    /// @param gameId The id of the game
    /// @param period The period for which to fetch the winner
    /// @return The address of the player who is the winner for the given period in the game
    function getWinner(uint256 gameId, uint256 period) external view returns (address) {
        return _turns[gameId][period].player;
    }

    /// @notice Fetches the protocol fee
    /// @return The protocol fee as a percentage
    function getFee() external pure returns (uint256) {
        return FEE;
    }

    /// @notice Fetches the protocol revenue for a given token
    /// @param token The address of the token
    /// @return The revenue for the given token
    function getRevenue(address token) external view returns (uint256) {
        return _revenue[token];
    }

    ///////////////////////
    // Internal Functions
    ///////////////////////

    /// @notice Callback function used by VRF Coordinator to provide a random number.We use the random number to decide the order of the players
    /// @param requestId The id of the request that was obained when calling `requestRandomWords`
    /// @param randomWords The random number provided by the VRF Coordinator
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        uint256 word = randomWords[0];
        Game storage game = _games[requestId];
        uint256 numberOfPlayers = game.players.length;
        address[] memory players = game.players;

        // Create en empty array with the turn of the players
        uint256[] memory playerIndexes = new uint256[](numberOfPlayers);
        for (uint256 i = 0; i < numberOfPlayers; i++) {
            playerIndexes[i] = i;
        }

        // Fisher-Yates shuffle
        for (uint256 i = numberOfPlayers - 1; i > 0; i--) {
            uint256 j = word % (i + 1);
            word /= 10;
            // Swap playerIndexes[i] and playerIndexes[j]
            (playerIndexes[i], playerIndexes[j]) = (playerIndexes[j], playerIndexes[i]);
        }

        // Set the turn order in the _turns mapping
        for (uint256 i = 0; i < numberOfPlayers; i++) {
            _turns[requestId][i] = Turn(players[playerIndexes[i]], 0); //initial prize for all periods is zero since there are no deposits
        }

        // Now we are ready to start the game
        game.ready = true;
    }
}
