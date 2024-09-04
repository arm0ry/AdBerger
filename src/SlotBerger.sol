// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.4;

import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";

struct Slot {
    string content; // provided by user
    uint256 price; // provided by user
    uint256 deposit; // provided by user
    address user; // provided by user
    uint40 timeLastTaxCollected; // automated by contract
    address currency; // accepted by DAO
    uint40 timeLastSlotted; // automated by contract
}

/// @notice Slotting with Harberger Tax.
/// @author audsssy.eth
contract SlotBerger {
    /* -------------------------------------------------------------------------- */
    /*                                   Events.                                  */
    /* -------------------------------------------------------------------------- */

    /// @dev Emitted when new `Slot` is set.
    event Slotted(
        uint256 indexed id,
        uint256 indexed newPrice,
        string indexed slot
    );

    /* -------------------------------------------------------------------------- */
    /*                                   Error.                                   */
    /* -------------------------------------------------------------------------- */

    error Unauthorized();
    error NotAvailable();
    error InvalidCurrentPrice();
    error InvalidNewPrice();
    error TransferFailed();
    error NothingToCollect();
    error InvalidCurrency();

    /* -------------------------------------------------------------------------- */
    /*                                  Storage.                                  */
    /* -------------------------------------------------------------------------- */

    /// @dev Address authorized to `collect` and `pull`.
    address public dao;

    /// @dev Percentage of patronage.
    uint40 public immutable tax;

    /// @dev Bidding cycle.
    uint40 public immutable cycle;

    /// @dev Minimum increase per use.
    uint40 public immutable minimum;

    /// @dev Id for slot.
    uint256 public slotId;

    /// @dev Mapping of `Slot` by `slotId`.
    mapping(uint256 id => Slot) slots;

    /// @dev Mapping of currencies accepted by `dao`.
    mapping(address currency => bool) public accepted;

    /* -------------------------------------------------------------------------- */
    /*                          Constructors & Modifier.                          */
    /* -------------------------------------------------------------------------- */

    constructor(address _dao) {
        dao = _dao;

        accepted[address(0)] = true;

        tax = 100; // 100 / 10000
        cycle = 1 minutes; // cycle
        // minimum = 0; // minimum increase per change of hand
    }

    modifier authorized() {
        if (msg.sender != dao) revert Unauthorized();
        _;
    }

    /* -------------------------------------------------------------------------- */
    /*                                 Use a Slot.                                */
    /* -------------------------------------------------------------------------- */

    /// @dev Use a slot.
    function use(
        uint256 id,
        string calldata content,
        address currency,
        uint256 currentPrice,
        uint256 newPrice
    ) public payable {
        if (id == 0) {
            // Check approved `currency`.
            if (accepted[currency]) revert InvalidCurrency();

            // Must deposit `newPrice` to cover full tax amount.
            if (newPrice != msg.value) revert InvalidNewPrice();

            unchecked {
                ++slotId;
            }

            setSlot(slotId, content, currency, newPrice);
        } else {
            Slot memory $ = slots[id];

            // Check bidding cycle.
            if ($.timeLastSlotted + cycle > block.timestamp) {
                revert NotAvailable();
            }

            // Check `currentPrice` and `newPrice` conditions.
            if (currentPrice != $.price && msg.value > currentPrice) {
                revert InvalidCurrentPrice();
            }
            if (newPrice < currentPrice + (currentPrice * minimum) / 10000) {
                revert InvalidNewPrice();
            }

            // Check `currency`.
            if ($.currency != currency) revert InvalidCurrency();

            // Calculate collection for buyout.
            uint256 collection = patronageOwed(id);

            // Take collection.
            route(currency, address(this), dao, collection);

            // Refund.
            route(currency, address(this), $.user, $.deposit - collection);

            setSlot(id, content, currency, newPrice);
        }
    }

    /// @dev Internal function to set slot.
    function setSlot(
        uint256 id,
        string calldata content,
        address currency,
        uint256 newPrice
    ) internal {
        slots[id].content = content;
        slots[id].price = newPrice;
        slots[id].deposit = msg.value;
        slots[id].user = msg.sender;
        slots[id].currency = currency;

        slots[id].timeLastSlotted = uint40(block.timestamp);
        slots[id].timeLastTaxCollected = uint40(block.timestamp);

        emit Slotted(id, newPrice, content);
    }

    /* -------------------------------------------------------------------------- */
    /*                                 Get a Slot.                                */
    /* -------------------------------------------------------------------------- */

    function getSlot(uint256 id) public view returns (Slot memory) {
        return slots[id];
    }

    /* -------------------------------------------------------------------------- */
    /*                                    DAO.                                    */
    /* -------------------------------------------------------------------------- */

    /// @dev Collect any patronage owed by a given `Slot`.
    function collect(
        uint256 id
    ) public payable authorized returns (uint256, uint256) {
        uint256 collection = patronageOwed(id);
        Slot memory $ = slots[id];

        if (collection > 0) {
            slots[id].timeLastTaxCollected = uint40(block.timestamp);

            if (collection >= $.deposit) {
                // Foreclose.
                delete slots[id];

                // Take deposit.
                route($.currency, address(this), dao, $.deposit);
                return ($.deposit, 0);
            } else {
                // Take collection.
                route($.currency, address(this), dao, collection);
                return (collection, slots[id].deposit = $.deposit - collection);
            }
        } else {
            return (0, 0);
        }
    }

    /// @dev Pull a given `Slot`.
    function pull(uint256 id) public payable authorized {
        Slot memory $ = slots[id];

        // Delete slot.
        delete slots[id];

        // Make collection, if any.
        (, uint256 refund) = collect(id);

        // Refund.
        if (refund > 0) {
            (bool success, ) = $.user.call{value: refund}("");
            if (!success) revert TransferFailed();
        }
    }

    function setDao(address _dao) public payable authorized {
        dao = _dao;
    }

    function manageCurrency(
        address currency,
        bool status
    ) public payable authorized {
        accepted[currency] = status;
    }

    /* -------------------------------------------------------------------------- */
    /*                                   Helper.                                  */
    /* -------------------------------------------------------------------------- */

    /// @dev Helper function to calculate patronage owed.
    // credit: simondlr  https://github.com/simondlr/thisartworkisalwaysonsale/blob/master/packages/hardhat/contracts/v1/ArtStewardV2.sol
    function patronageOwed(
        uint256 id
    ) public view returns (uint256 patronageDue) {
        Slot memory $ = slots[id];

        return
            (($.price * (block.timestamp - $.timeLastTaxCollected)) * tax) /
            10000 /
            365 days;
    }

    function route(
        address currency,
        address from,
        address to,
        uint256 amount
    ) internal {
        if (currency == address(0)) {
            (bool success, ) = to.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(currency).transferFrom(from, to, amount);
        }
    }

    receive() external payable virtual {}
}
