// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.4;

contract AdvertBerger {
    event Advertised(
        uint256 indexed id,
        string indexed advert,
        uint256 indexed newPrice
    );

    // TODO: Error.

    error Unauthorized();
    error NotAvailable();
    error InvalidCurrentPrice();
    error InvalidNewPrice();
    error TransferFailed();

    // TODO: Storage.

    address public dao;

    uint256 public timeLastCollected;

    uint256 public advertId;

    // Advert.
    mapping(uint256 id => string advert) public adverts;

    // Advertisers.
    mapping(uint256 id => address advertiser) public advertisers;

    // Price to advert.
    mapping(uint256 id => uint256 price) public prices;

    // Deposit for advert.
    mapping(uint256 id => uint256 deposit) public deposits;

    // Tax to advert.
    mapping(uint256 id => uint256 tax) public taxes;

    // Time last advertised.
    mapping(uint256 id => uint256 timestamp) public timeLastAdvertised;

    // Bidding cycle.
    mapping(uint256 id => uint256 second) public cycles;

    // Minimum bid increase.
    mapping(uint256 id => uint256 minimum_bid_increase) public minimums;

    // TODO: Constructors & Modifier.

    constructor(address _dao) {
        dao = _dao;
        timeLastCollected = block.timestamp;
    }

    modifier authorized() {
        if (msg.sender != dao) revert Unauthorized();
        _;
    }

    // TODO: Advertiser Flow.

    function advertise(
        uint256 id,
        string calldata advert,
        uint256 currentPrice,
        uint256 newPrice
    ) public payable {
        if (id == 0) {
            unchecked {
                ++advertId;
            }

            // Make deposit.
            if (newPrice != msg.value) revert InvalidNewPrice();
            deposits[advertId] = msg.value;

            _advert(advertId, advert, newPrice);
        } else {
            // Check if advert by advertId is in bidding cycle.
            uint256 _timeLastAdvertised = timeLastAdvertised[id];
            uint256 _cycle = cycles[id];
            if (_timeLastAdvertised + _cycle > block.timestamp) {
                revert NotAvailable();
            }

            // Validate current and new price for new advert.
            if (currentPrice != prices[id] && msg.value > currentPrice) {
                revert InvalidCurrentPrice();
            }
            uint256 min = minimums[id];
            if (newPrice < currentPrice + (currentPrice * min) / 10000)
                revert InvalidNewPrice();

            // Calculate collection for buyout.
            uint256 collection = patronageOwed(id);

            // Take collection.
            (bool success, ) = dao.call{value: collection}("");
            if (!success) revert TransferFailed();

            // Calculate refund.
            uint256 refund = deposits[id] - collection;
            deposits[id] = msg.value;

            // Refund.
            (success, ) = advertisers[id].call{value: refund}("");
            if (!success) revert TransferFailed();

            _advert(id, advert, newPrice);
        }
    }

    function _advert(
        uint256 id,
        string calldata advert,
        uint256 newPrice
    ) internal {
        adverts[id] = advert;
        prices[id] = newPrice;
        timeLastAdvertised[id] = block.timestamp;
        advertisers[id] = msg.sender;

        // TODO: Hardcoded.
        cycles[id] = 1 minutes;
        minimums[id] = 0;
        taxes[id] = 100; // 100 / 10000

        emit Advertised(id, advert, newPrice);
    }

    // TODO: DAO.

    function collect(uint256 id) public payable authorized {
        uint256 collection = patronageOwed(id);
        uint256 deposit = deposits[id];

        if (collection >= deposit) {
            // Foreclose.
            delete deposits[id];
            delete adverts[id];
            delete prices[id];
            delete advertisers[id];
            delete taxes[id];
            delete cycles[id];

            // Take deposit.
            (bool success, ) = dao.call{value: deposit}("");
            if (!success) revert TransferFailed();
        } else {
            // Calculate deposit minus collection.
            deposits[id] = deposit - collection;

            // Take collection.
            (bool success, ) = dao.call{value: collection}("");
            if (!success) revert TransferFailed();
        }

        timeLastCollected = block.timestamp;
    }

    function pull(uint256 id) public payable authorized {
        // Remove advert and its price.
        delete adverts[id];
        delete prices[id];

        // Make collection, if any.
        collect(id);

        // Refund.
        (bool success, ) = advertisers[id].call{value: deposits[id]}("");
        if (!success) revert TransferFailed();
    }

    function setDao(address _dao) public payable authorized {
        dao = _dao;
    }

    // credit: simondlr  https://github.com/simondlr/thisartworkisalwaysonsale/blob/master/packages/hardhat/contracts/v1/ArtStewardV2.sol
    function patronageOwed(
        uint256 id
    ) public view returns (uint256 patronageDue) {
        return
            ((prices[id] * (block.timestamp - timeLastCollected)) * taxes[id]) /
            10000 /
            365 days;
    }

    receive() external payable virtual {}
}
