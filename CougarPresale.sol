// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";

contract CougarPresale is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // The number of unclaimed COUGAR tokens the user has
    mapping(address => uint256) public cougarUnclaimed;
    // Last time user claimed COUGAR
    mapping(address => uint256) public lastCougarClaimed;

    // COUGAR token
    IBEP20 public COUGAR;
    // Buy token
    IBEP20 public BuyToken;
    // Sale active
    bool public isSaleActive;
    // Claim active
    bool public isClaimActive;
    // Starting timestamp
    uint256 public startingTimeStamp;
    
    // Max Min timestamp 10 days
    uint256 public constant MaxMinstartingTimeStamp = 864000;
    
    // Total COUGAR sold
    uint256 public totalCougarSold = 0;

    // Price of presale COUGAR: 0.01 BuyToken
    uint256 private constant BuyTokenPerCGS = 1;

    // Time per percent
    uint256 private timePerPercent = 600; // 10 minutes

    // Max Time per percent
    uint256 public constant maxTimePerPercent = 1800; // 30 minutes

    // Max Buy Per User
    uint256 public maxBuyPerUser = 5000000*(1e6); // decimal 6

    uint256 public firstHarvestTimestamp;

    address payable owner;

    uint256 public constant COUGAR_HARDCAP = 15000000*(1e6);

    modifier onlyOwner() {
        require(msg.sender == owner, "You're not the owner");
        _;
    }

    event TokenBuy(address user, uint256 tokens);
    event TokenClaim(address user, uint256 tokens);
    event MaxBuyPerUserUpdated(address user, uint256 previousRate, uint256 newRate);

    constructor(
        address _COUGAR,
        uint256 _startingTimestamp,
        address _BuyTokenAddress
    ) public {
        COUGAR = IBEP20(_COUGAR);
        BuyToken = IBEP20(_BuyTokenAddress);
        isSaleActive = true;
        isClaimActive = false;
        owner = msg.sender;
        startingTimeStamp = _startingTimestamp;
    }

    function setSaleActive(bool _isSaleActive) external onlyOwner {
        isSaleActive = _isSaleActive;
    }

    function setClaimActive(bool _isClaimActive) external onlyOwner {
        isClaimActive = _isClaimActive;
        if (firstHarvestTimestamp == 0 && _isClaimActive) {
            firstHarvestTimestamp = block.timestamp;
        }
    }

    function buy(uint256 _amount, address _buyer) public nonReentrant {
        require(isSaleActive, "Presale has not started");
        require(
            block.timestamp >= startingTimeStamp,
            "Presale has not started"
        );

        address buyer = _buyer;
        uint256 tokens = _amount.div(BuyTokenPerCGS).mul(100);

        require(
            totalCougarSold + tokens <= COUGAR_HARDCAP,
            "Cougar presale hardcap reached"
        );

        require(
            cougarUnclaimed[buyer] + tokens <= maxBuyPerUser,
            "Your amount exceeds the max buy number"
        );

        BuyToken.safeTransferFrom(buyer, address(this), _amount);

        cougarUnclaimed[buyer] = cougarUnclaimed[buyer].add(tokens);
        totalCougarSold = totalCougarSold.add(tokens);
        emit TokenBuy(buyer, tokens);
    }

    function claim() external {
        require(isClaimActive, "Claim is not allowed yet");
        require(
            cougarUnclaimed[msg.sender] > 0,
            "User should have unclaimed COUGAR tokens"
        );
        require(
            COUGAR.balanceOf(address(this)) >= cougarUnclaimed[msg.sender],
            "There are not enough COUGAR tokens to transfer."
        );

        if (lastCougarClaimed[msg.sender] == 0) {
            lastCougarClaimed[msg.sender] = firstHarvestTimestamp;
        }

        uint256 allowedPercentToClaim = block
        .timestamp
        .sub(lastCougarClaimed[msg.sender])
        .div(timePerPercent);

        require(
            allowedPercentToClaim > 0,
            "User cannot claim COUGAR tokens when Percent is 0%"
        );

        if (allowedPercentToClaim > 100) {
            allowedPercentToClaim = 100;
            // ensure they cannot claim more than they have.
        }

        lastCougarClaimed[msg.sender] = block.timestamp;

        uint256 cougarToClaim = cougarUnclaimed[msg.sender]
        .mul(allowedPercentToClaim)
        .div(100);
        cougarUnclaimed[msg.sender] = cougarUnclaimed[msg.sender].sub(cougarToClaim);

        cougarToClaim = cougarToClaim.mul(1e12);
        COUGAR.safeTransfer(msg.sender, cougarToClaim);
        emit TokenClaim(msg.sender, cougarToClaim);
    }


    function withdrawFunds() external onlyOwner {
        BuyToken.safeTransfer(msg.sender, BuyToken.balanceOf(address(this)));
    }

    function withdrawUnsoldCOUGAR() external onlyOwner {
        uint256 amount = COUGAR.balanceOf(address(this)) - totalCougarSold.mul(1e12);
        COUGAR.safeTransfer(msg.sender, amount);
    }

    function emergencyWithdraw() external onlyOwner {
        COUGAR.safeTransfer(msg.sender, COUGAR.balanceOf(address(this)));
    }

    function updateMaxBuyPerUser(uint256 _maxBuyPerUser) external onlyOwner {
        require(_maxBuyPerUser <= COUGAR_HARDCAP, "COUGAR::updateMaxBuyPerUser: maxBuyPerUser must not exceed the hardcap.");
        emit MaxBuyPerUserUpdated(msg.sender, maxBuyPerUser, _maxBuyPerUser);
        maxBuyPerUser = _maxBuyPerUser;
    }

    function updateTimePerPercent(uint256 _timePerPercent) external onlyOwner {
        require(_timePerPercent <= maxTimePerPercent, "COUGAR::updateTimePerPercent: updateTimePerPercent must not exceed the maxTimePerPercent.");
        timePerPercent = _timePerPercent;
    }

    function updateStartingTimeStamp(uint256 _startingTimeStamp) external onlyOwner {
        require(_startingTimeStamp <= (startingTimeStamp+MaxMinstartingTimeStamp), "COUGAR::updateTimePerPercent: updateTimePerPercent must not exceed the MaxstartingTimeStamp.");
        require(_startingTimeStamp >= (startingTimeStamp-MaxMinstartingTimeStamp), "COUGAR::updateTimePerPercent: updateTimePerPercent must not exceed the MinstartingTimeStamp.");
        startingTimeStamp = _startingTimeStamp;
    }

}