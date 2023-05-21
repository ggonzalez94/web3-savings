// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "openzeppelin-contracts/access/Ownable.sol";
import "openzeppelin-contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

contract Pasanaku is Ownable {
    using SafeERC20 for IERC20;

    struct Game {
        uint256 startDate; // the time when the game started
        uint256 frequency; //should we set a min and max cap on the frequency to avoid periods being super short or super long?
        uint256 amount; // to be deposited every period
        address token; //should we have a set of allowed tokens?
    }

    struct Player {
        bool isPlaying;
        uint256 lastPlayed; // the last time the player deposited
    }

    mapping(uint256 id => Game game) private _games;
    mapping(uint256 gameId => mapping(address playerAddress => Player player))
        private _players; // a separate mapping made more sense for gas costs and code complexity

    // starts a new game
    function start(
        uint256 frequency,
        uint256 amount,
        address[] memory players,
        address token
    ) external {
        require(frequency > 0, "Pasanaku: frequency must be greater than 0");
        uint256 id = uint256(
            keccak256(abi.encodePacked(msg.sender, block.timestamp))
        ); //decide on a better way to get the id?
        // create game
        _games[id] = Game(block.timestamp, frequency, amount, token);
        // add players to the game
        for (uint256 i = 0; i < players.length; i++) {
            _players[id][msg.sender] = Player(true, block.timestamp);
        }
    }

    function deposit(uint256 gameId, uint256 amount) external {
        Game storage game = _games[gameId];
        Player storage player = _players[gameId][msg.sender];
        uint256 gameAmount = game.amount; //avoid reading multiple times from storage
        //revert if amount is not equal to the amount set for the game
        require(
            amount == gameAmount,
            "Pasanaku: amount is not equal to the amount set for the game"
        );
        //revert if msg.sender is not part of the players array
        require(
            _isPlayer(gameId, msg.sender),
            "Pasanaku: msg.sender is not part of the players array"
        );

        //revert if we are outside the current period
        uint256 currentPeriod = (block.timestamp - game.startDate) /
            game.frequency;
        require(
            block.timestamp >= game.startDate + currentPeriod * game.frequency,
            "Pasanaku: we are outside the current period"
        );

        //TODO: revert if the game has finished(currentPeriod == amount of players)

        //revert if player has already played in the current period
        bool hasPlayedInCurrentPeriod;
        if (player.lastPlayed > 0) {
            uint256 lastPlayedPeriod = (player.lastPlayed - game.startDate) /
                game.frequency;
            hasPlayedInCurrentPeriod = currentPeriod <= lastPlayedPeriod; //lastPlayedPeriod should never be greater than current period, at most equal
        }
        require(
            !hasPlayedInCurrentPeriod,
            "Pasanaku: player has already played in the current period"
        );

        // update state
        player.lastPlayed = block.timestamp;

        // transfer tokens
        IERC20(game.token).safeTransferFrom(
            msg.sender,
            address(this),
            gameAmount
        );
    }

    function _isPlayer(
        uint256 game,
        address player
    ) internal view returns (bool isPlaying) {
        isPlaying = _players[game][player].isPlaying;
    }

    function _canPlay(
        uint256 gameId,
        address playerAddress
    ) internal view returns (bool) {
        Game storage game = _games[gameId];
        Player storage player = _players[gameId][playerAddress];

        uint256 currentPeriod = (block.timestamp - game.startDate) /
            game.frequency;
        bool isCurrentPeriod = block.timestamp >=
            game.startDate + currentPeriod * game.frequency;

        bool hasPlayedInCurrentPeriod;
        if (player.lastPlayed == 0) {
            hasPlayedInCurrentPeriod = false;
        } else {
            uint256 lastPlayedPeriod = (player.lastPlayed - game.startDate) /
                game.frequency;
            hasPlayedInCurrentPeriod = currentPeriod <= lastPlayedPeriod;
        }

        return (isCurrentPeriod && !hasPlayedInCurrentPeriod);
    }
}
