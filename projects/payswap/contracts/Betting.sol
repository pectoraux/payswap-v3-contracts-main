// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "./Library.sol";

// Gauges are used to incentivize pools, they emit reward tokens over 7 days for staked LP tokens
contract Betting {
    using SafeERC20 for IERC20;

    address private contractAddress;
    mapping(address => uint) public pendingRevenue;
    mapping(address => mapping(address => uint)) public pendingReferrerFee;
    mapping(uint256 => mapping(string => uint256[])) private numberTicketsPerBettingId;
    mapping(uint => mapping(uint => uint[])) public countWinnersPerBracket;
    mapping(uint => mapping(uint => uint256[])) private tokenPerBracket;
    mapping(uint => mapping(uint => BettingStatus)) public status;
    mapping(uint => uint[]) public finalNumbers;
    mapping(uint => bytes32[]) private finalNumbers2;
    mapping(uint => uint[]) public rewardsBreakdown;
    mapping(uint => uint) private nextToSet;
    struct BettingEvent {
        address token;
        string action;
        bool alphabetEncoding;
        uint startTime;
        uint numberOfPeriods;
        uint nextToClose;
        uint adminShare;
        uint referrerShare;
        uint bracketDuration;
        uint pricePerTicket;
        uint discountDivisor;
        uint ticketRange;
        uint minTicketNumber;
    }
    struct BettingTicket {
        string letter;
        uint number;
        uint paid;
        uint rewards;
        uint bettingId;
        uint period;
        bool claimed;
        address owner;
    }
    uint private currentBettingId = 1;
    mapping(uint => BettingTicket) public tickets;
    mapping(uint => string) public subjects;
    mapping(uint => uint) public ticketSizes;
    mapping(uint => uint) private masks;
    mapping(uint => uint[]) public amountCollected;
    mapping(uint => BettingEvent) public protocolInfo;
    mapping(address => mapping(uint => uint)) public paymentCredits;
    address public devaddr_;
    address public oracle;
    address private helper;
    uint public collectionId;
    mapping(uint => string) private _description;
    mapping(uint => string) private _media;
    mapping(address => uint) public totalProcessed;
    mapping(address => bool) public isAdmin;
    mapping(uint => uint) public partnerEvent;
    uint256 private MASK = 111111;
    uint256 private MIN_TICKET_NUMBER = 1000000;
    uint256 private TICKET_RANGE = 999999;
    uint private TICKET_SIZE = 6;

    constructor(
        address _devaddr,
        address _helper,
        address _oracle,
        address _contractAddress
    ) {
        helper = _helper;
        devaddr_ = _devaddr;
        oracle = _oracle;
        isAdmin[devaddr_] = true;
        contractAddress = _contractAddress;
    }

    modifier onlyDev() {
        require(devaddr_ == msg.sender || 
        (collectionId > 0 && collectionId == IMarketPlace(IContract(contractAddress).marketCollections())
        .addressToCollectionId(msg.sender)));
        _;
    }

    modifier onlyAdmin() {
        require(isAdmin[msg.sender]);
        _;
    }

    // simple re-entrancy check
    uint internal _unlocked = 1;
    modifier lock() {
        require(_unlocked == 1);
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    function getAction(uint _bettingId) external view returns(string memory) {
        return protocolInfo[_bettingId].action;
    }

    function description(uint _ticketId) external view returns(string memory) {
        return _description[tickets[_ticketId].bettingId];
    }

    function media(uint _ticketId) external view returns(string memory) {
        return _media[tickets[_ticketId].bettingId];
    }

    function getToken(uint _ticketId) external view returns(address) {
        return protocolInfo[tickets[_ticketId].bettingId].token;
    }

    function getLetter(uint _ticketId) external view returns(string memory) {
        return protocolInfo[tickets[_ticketId].bettingId].alphabetEncoding
        ? tickets[_ticketId].letter
        : toString(tickets[_ticketId].number);
    }

    function updateAdmin(address _admin, bool _add) external onlyDev {
        isAdmin[_admin] = _add;
    }

    function updateDev(address _devaddr) external onlyDev {
        devaddr_ = _devaddr;
    }

    function updateParameters(
        uint _collectionId,
        uint _newMinTicketNumber,
        uint _newTicketRange,
        uint _ticketSize,
        uint _mask
    ) external onlyAdmin {
        MIN_TICKET_NUMBER = _newMinTicketNumber;
        TICKET_RANGE = _newTicketRange;
        TICKET_SIZE = _ticketSize;
        MASK = _mask;
        if (_collectionId > 0 && devaddr_ == msg.sender) {
            collectionId = IMarketPlace(IContract(contractAddress).marketCollections())
            .addressToCollectionId(msg.sender);
        }
    }

    function _minter() internal view returns(address) {
        return IContract(contractAddress).bettingMinter();
    }

    // function _trustBounty() internal view returns(address) {
    //     return IContract(contractAddress).trustBounty();
    // }

    // function setContractAddress(address _contractAddress) external {
    //     require(contractAddress == address(0x0) || helper == msg.sender);
    //     contractAddress = _contractAddress;
    //     helper = IContract(_contractAddress).bettingHelper();
    // }

    function _checkAuditorIdentityProof(address _owner, uint _identityTokenId) internal {
        if (collectionId > 0) {
            IMarketPlace(IContract(contractAddress).marketHelpers2())
            .checkPartnerIdentityProof(collectionId, _identityTokenId, _owner);
        }
    }

    function _sumArr(uint[] memory _rewardsBreakdown) internal pure returns(uint _total) {
        for (uint i = 0; i < _rewardsBreakdown.length; i++) {
            _total += _rewardsBreakdown[i];
        }
    }
    
    function updatePartnerEvent(uint _bettingId1, uint _bettingId2) external {
        IBetting(helper).checkMembership(msg.sender);
        require(
            protocolInfo[_bettingId1].startTime == 0 || 
            protocolInfo[_bettingId1].startTime > block.timestamp
        );
        require(
            protocolInfo[_bettingId2].startTime == 0 || 
            protocolInfo[_bettingId2].startTime > block.timestamp
        );
        require(partnerEvent[_bettingId1] == _bettingId1);
        partnerEvent[_bettingId1] = _bettingId2;
        partnerEvent[_bettingId2] = _bettingId1;
    }

    function updateBettingEvent(
        address _token,
        bool _alphabetEncoding,
        uint _startTime,
        uint _numberOfPeriods,
        uint _currentBettingId,
        uint[5] memory _values, //_adminShare,_referrerShare, _bracketDuration, _pricePerTicket, _discountDivisor
        uint[] memory _rewardsBreakdown,
        string memory _action,
        string memory __media,
        string memory __description,
        string memory _subjects
    ) external {
        if(_currentBettingId == 0) {
            IBetting(helper).checkMembership(msg.sender);
            require(IBetting(helper).maxAdminShare() >= _values[0]);
            _currentBettingId = currentBettingId++;
            subjects[_currentBettingId] = _subjects;
            protocolInfo[_currentBettingId].token = _token;
            protocolInfo[_currentBettingId].action = _action;
            protocolInfo[_currentBettingId].adminShare = _values[0];
            protocolInfo[_currentBettingId].referrerShare = _values[1];
            protocolInfo[_currentBettingId].bracketDuration = _values[2];
            rewardsBreakdown[_currentBettingId] = _rewardsBreakdown;
            partnerEvent[_currentBettingId] = _currentBettingId;
            require(_sumArr(_rewardsBreakdown) == 10000);
        }
        _startTime = block.timestamp + _startTime;
        masks[_currentBettingId] = MASK;
        ticketSizes[_currentBettingId] = TICKET_SIZE;
        protocolInfo[_currentBettingId].ticketRange = TICKET_RANGE;
        protocolInfo[_currentBettingId].pricePerTicket = _values[3];
        protocolInfo[_currentBettingId].discountDivisor = _values[4];
        protocolInfo[_currentBettingId].minTicketNumber = MIN_TICKET_NUMBER;
        protocolInfo[_currentBettingId].alphabetEncoding = _alphabetEncoding;
        protocolInfo[_currentBettingId].numberOfPeriods = _numberOfPeriods == 0 ? IContract(contractAddress).maximumSize() : _numberOfPeriods;
        if (
            protocolInfo[_currentBettingId].startTime == 0 || 
            protocolInfo[_currentBettingId].startTime > block.timestamp
        ) {
            protocolInfo[_currentBettingId].startTime = _startTime;
            _media[_currentBettingId] = __media;
            _description[_currentBettingId] = __description;
        }
        IBetting(helper).emitUpdateProtocol(
            _currentBettingId,
            _startTime,
            _token,
            _action, 
            _values,
            _rewardsBreakdown,
            _subjects,
            __media,
            __description
        );
    }

    function _checkIdentityProof(address _owner, uint _identityTokenId, uint _bettingTicketId) public {
        if (collectionId > 0) {
            IMarketPlace(IContract(contractAddress).marketHelpers2())
            .checkOrderIdentityProof(collectionId, _identityTokenId, _owner, string(abi.encodePacked(_bettingTicketId)));
        }
    }

    /**
     * @notice Buy tickets for the current lottery
     * @param _ticketNumbers: array of ticket numbers between 1,000,000 and 1,999,999
     * @dev Callable by users
     */
    function buyWithContract(
        uint _bettingTicketId, 
        address _user, 
        address _referrer, 
        uint _identityTokenId, 
        uint _bettingPeriod,
        uint[] calldata _ticketNumbers,
        string[] calldata _ticketNumbers2
    ) external {
        uint _period = Math.max(
            _bettingPeriod,
            (block.timestamp - protocolInfo[_bettingTicketId].startTime) / protocolInfo[_bettingTicketId].bracketDuration
        );
        // _period = Math.max(_bettingPeriod, _period);
        require(protocolInfo[_bettingTicketId].numberOfPeriods > _period && protocolInfo[_bettingTicketId].startTime <= block.timestamp);
        // require(status[_bettingTicketId][_period] == BettingStatus.Open,"B1");
        // require(protocolInfo[_bettingTicketId].startTime <= block.timestamp);
        _checkIdentityProof(_user, _identityTokenId, _bettingTicketId);
        // Calculate number of token to this contract
        // uint _length = protocolInfo[_bettingTicketId].alphabetEncoding ? _ticketNumbers2.length : _ticketNumbers.length;
        uint256 _amountToTransfer = _calculateTotalPriceForBulkTickets(
            _ticketNumbers.length,
            _bettingTicketId,
            _user
        );
        _injectFunds(_bettingTicketId, _period, _amountToTransfer);
        if (_referrer != address(0x0) && _referrer != _user) {
            pendingReferrerFee[_referrer][protocolInfo[_bettingTicketId].token] += protocolInfo[_bettingTicketId].referrerShare * _amountToTransfer / 10000;
        }
        for (uint256 i = 0; i < _ticketNumbers.length; i++) {
            if (protocolInfo[_bettingTicketId].alphabetEncoding) {
                for (uint k = numberTicketsPerBettingId[_bettingTicketId][_ticketNumbers2[i]].length; k < _period + 1; k++) {
                    numberTicketsPerBettingId[_bettingTicketId][_ticketNumbers2[i]].push(0);
                }
                numberTicketsPerBettingId[_bettingTicketId][_ticketNumbers2[i]][_period]++;
            } else {
                _processTicket(_bettingTicketId, _ticketNumbers[i], _period);
            }
            uint _ticketId = IBetting(_minter()).mint(_user);
            tickets[_ticketId] = BettingTicket({
                number: _ticketNumbers[i],
                letter: _ticketNumbers2[i],
                paid: _amountToTransfer / _ticketNumbers.length,
                period: _period,
                rewards: 0,
                claimed: false,
                bettingId: _bettingTicketId,
                owner: _user
            });
            IBetting(helper).emitTicketsPurchase(
                _user, 
                _bettingTicketId, 
                _amountToTransfer, 
                _ticketId, 
                _ticketNumbers[i],
                _ticketNumbers2[i],
                 _period
            );
        }
    }

    function toString(uint value) internal pure returns (string memory) {
        // Inspired by OraclizeAPI's implementation - MIT license
        // https://github.com/oraclize/ethereum-api/blob/b42146b063c7d6ee1358846c198246239e9360e8/oraclizeAPI_0.4.25.sol

        if (value == 0) {
            return "0";
        }
        uint temp = value;
        uint digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _processTicket(uint _bettingTicketId, uint _ticketNumber, uint _period) internal {
        require((_ticketNumber >= protocolInfo[_bettingTicketId].minTicketNumber) && (_ticketNumber <= protocolInfo[_bettingTicketId].minTicketNumber + protocolInfo[_bettingTicketId].ticketRange));
        for(uint k = 0; k < ticketSizes[_bettingTicketId]; k++) {
            uint _power = uint(10)**(ticketSizes[_bettingTicketId] - k);
            string memory _transformed = toString(_ticketNumber % _power + masks[_bettingTicketId] % _power);
            for (uint j = numberTicketsPerBettingId[_bettingTicketId][_transformed].length; j < _period + 1; j++) {
                numberTicketsPerBettingId[_bettingTicketId][_transformed].push(0);
            }
            numberTicketsPerBettingId[_bettingTicketId][_transformed][_period]++;
        }
    }

    function injectFunds(uint _bettingTicketId, uint _period, uint _amountToTransfer) external {
        _injectFunds(_bettingTicketId, _period, _amountToTransfer);
        IBetting(helper).emitInjectFunds(msg.sender, _bettingTicketId, _amountToTransfer, _period);
    }
    
    function _injectFunds(uint _bettingTicketId, uint _period, uint _amountToTransfer) internal lock {
        IERC20(protocolInfo[_bettingTicketId].token).safeTransferFrom(msg.sender, address(this), _amountToTransfer);
        totalProcessed[protocolInfo[_bettingTicketId].token] += _amountToTransfer;
        if (amountCollected[_bettingTicketId].length >= _period + 1) {
            amountCollected[_bettingTicketId][_period] += _amountToTransfer;
        } else {
            for (uint i = amountCollected[_bettingTicketId].length; i < _period; i++) {
                amountCollected[_bettingTicketId].push(0);
            }
            amountCollected[_bettingTicketId].push(_amountToTransfer);
        }
    }

    /**
     * @notice Claim a set of winning tickets for a lottery
     * @param _bettingId: lottery id
     * @param _ticketIds: array of ticket ids
     * @param _brackets: array of brackets for the ticket ids
     * @dev Callable by users only, not contract!
     */
    function claimTickets(
        uint256 _bettingId,
        uint256[] calldata _ticketIds,
        uint[] calldata _brackets
    ) external lock {
        // require(_ticketIds.length == _brackets.length);
        // require(_ticketIds.length != 0 && _ticketIds.length <= IContract(contractAddress).maximumSize());
        
        for (uint256 i = 0; i < _ticketIds.length; i++) {
            // require(_brackets[i] < ticketSizes[_bettingId]); // Must be between 0 and TICKET_SIZE - 1

            // uint256 thisTicketId = _ticketIds[i];
            require(
                _brackets[i] < ticketSizes[_bettingId] &&
                status[_bettingId][tickets[_ticketIds[i]].period] == BettingStatus.Claimable && 
                !tickets[_ticketIds[i]].claimed
            );

            // require(!tickets[_ticketIds[i]].claimed);
            // Update the lottery ticket owner to 0x address
            tickets[_ticketIds[i]].claimed = true;
            uint256 rewardForTicketId = calculateRewardsForTicketId(_bettingId, _ticketIds[i], _brackets[i]);
            
            // Check user is claiming the correct bracket
            if(rewardForTicketId != 0) {
                // Transfer money to msg.sender
                uint _adminFee = rewardForTicketId * protocolInfo[_bettingId].adminShare / 10000;
                uint _payswapFees = rewardForTicketId * IBetting(helper).tradingFee() / 10000;
                tickets[_ticketIds[i]].rewards = rewardForTicketId - _adminFee - _payswapFees;
                pendingRevenue[protocolInfo[partnerEvent[_bettingId]].token] += _adminFee;
                
                erc20(protocolInfo[partnerEvent[_bettingId]].token).approve(helper, _payswapFees);
                IBetting(helper).notifyFees(protocolInfo[partnerEvent[_bettingId]].token, _payswapFees);
            
                IBetting(helper).emitTicketsClaim(protocolInfo[partnerEvent[_bettingId]].token, rewardForTicketId, _bettingId, _ticketIds[i]);
            }
        }
    }

    function closeBetting(uint256 _bettingId) external {
        uint _period = Math.min(
            (block.timestamp - protocolInfo[_bettingId].startTime) / protocolInfo[_bettingId].bracketDuration,
            protocolInfo[_bettingId].numberOfPeriods
        );
        for (uint i = protocolInfo[_bettingId].nextToClose; i < _period; i++) {
            status[_bettingId][i] = BettingStatus.Close;
            IBetting(helper).emitCloseBetting(_bettingId, i);
        }
        protocolInfo[_bettingId].nextToClose = _period;
    }

    /**
     * @notice Draw the final number, calculate reward in token per group, and make lottery claimable
     * @param _bettingId: lottery id
     * @dev Callable by operator
     */
    function setBettingResults(
        uint256 _bettingId, 
        uint _identityTokenId, 
        uint[] memory _finalNumbers
    ) external lock {
        if (oracle == address(0x0)) {
            _checkAuditorIdentityProof(msg.sender, _identityTokenId);
        } else {
            require(oracle == msg.sender);
        }
        require(protocolInfo[_bettingId].nextToClose >= (nextToSet[_bettingId] + _finalNumbers.length) && !protocolInfo[_bettingId].alphabetEncoding);

        uint _fIdx;
        for (uint i = nextToSet[_bettingId]; i < nextToSet[_bettingId] + _finalNumbers.length; i++) {
            uint256 amountToWithdrawToTreasury;
            // require(status[_bettingId][i] == BettingStatus.Close, "B18");
            // Initialize a number to count addresses in the previous bracket
            uint256 numberAddressesInPreviousBracket;
            // Calculate the amount to share post-treasury fee
            if (amountCollected[partnerEvent[_bettingId]].length <= i) amountCollected[partnerEvent[_bettingId]].push(0);
            uint256 amountToShareToWinners =  (
                (amountCollected[partnerEvent[_bettingId]][i] * (10000 - protocolInfo[_bettingId].adminShare))
            ) / 10000;
            // Initializes the amount to withdraw to treasury
            countWinnersPerBracket[_bettingId][i] = new uint[](ticketSizes[_bettingId]);
            tokenPerBracket[_bettingId][i] = new uint[](ticketSizes[_bettingId]);

            // Calculate prizes in token for each bracket by starting from the highest one
            for (uint k = 0; k < ticketSizes[_bettingId]; k++) {
                uint j = ticketSizes[_bettingId] - k - 1;
                string memory transformedWinningNumber = toString(masks[_bettingId] % uint(10)**(j + 1) + _finalNumbers[_fIdx] % (uint(10)**(j + 1)));
                
                if (numberTicketsPerBettingId[_bettingId][transformedWinningNumber].length > i) {
                    countWinnersPerBracket[_bettingId][i][j] = (numberTicketsPerBettingId[_bettingId][transformedWinningNumber][i] > numberAddressesInPreviousBracket
                    ? numberTicketsPerBettingId[_bettingId][transformedWinningNumber][i] - numberAddressesInPreviousBracket
                    : 0); 
                    // * rewardsBreakdown[_bettingId][k] / Math.max(1,rewardsBreakdown[_bettingId][k]);
                }
                // A. If number of users for this _bracket number is superior to 0
                if (
                    numberTicketsPerBettingId[_bettingId][transformedWinningNumber].length > i &&
                    numberTicketsPerBettingId[_bettingId][transformedWinningNumber][i] > numberAddressesInPreviousBracket
                ) {
                    // B. If rewards at this bracket are > 0, calculate, else, report the numberAddresses from previous bracket
                    if (rewardsBreakdown[_bettingId][j] != 0) {
                        tokenPerBracket[_bettingId][i][j] = //(rewardsBreakdown[_bettingId][k] * amountToShareToWinners) / 10000;
                        ((rewardsBreakdown[_bettingId][j] * amountToShareToWinners) /
                            (numberTicketsPerBettingId[_bettingId][transformedWinningNumber][i] - numberAddressesInPreviousBracket)) / 10000;

                        // Update numberAddressesInPreviousBracket
                        numberAddressesInPreviousBracket = numberTicketsPerBettingId[_bettingId][transformedWinningNumber][i];
                    }
                    // A. No token to distribute, they are added to the amount to withdraw to treasury address
                } else {
                    tokenPerBracket[_bettingId][i][j] = 0;
                    amountToWithdrawToTreasury += (rewardsBreakdown[_bettingId][j] * amountToShareToWinners) / 10000;
                }
            }
            status[_bettingId][i] = BettingStatus.Claimable;
            amountToWithdrawToTreasury += (amountCollected[partnerEvent[_bettingId]][i] - amountToShareToWinners);
            
            // // Transfer token to admin address
            // if (amountToWithdrawToTreasury > 0) {
                erc20(protocolInfo[_bettingId].token).approve(helper, amountToWithdrawToTreasury);
                IBetting(helper).notifyFees(protocolInfo[_bettingId].token, amountToWithdrawToTreasury);
            // }
            
            IBetting(helper).emitBettingResultsIn(_bettingId, i, msg.sender, _finalNumbers[_fIdx++]);
        }
        // Update internal statuses for lottery
        finalNumbers[_bettingId] = _finalNumbers;
        nextToSet[_bettingId] += _finalNumbers.length;
    }

    function setBettingResults2(
        uint256 _bettingId, 
        uint _identityTokenId, 
        string[] memory _finalNumbers
    ) external lock {
        if (oracle == address(0x0)) {
            _checkAuditorIdentityProof(msg.sender, _identityTokenId);
        } else {
            require(oracle == msg.sender);
        }
        require(protocolInfo[_bettingId].nextToClose >= (nextToSet[_bettingId] + _finalNumbers.length) && protocolInfo[_bettingId].alphabetEncoding);

        uint _fIdx;
        for (uint i = nextToSet[_bettingId]; i < nextToSet[_bettingId] + _finalNumbers.length; i++) {
            uint256 amountToWithdrawToTreasury;
            // require(status[_bettingId][i] == BettingStatus.Close, "B18");
            // Initialize a number to count addresses in the previous bracket
            uint256 numberAddressesInPreviousBracket;
            // Calculate the amount to share post-treasury fee
            if (amountCollected[partnerEvent[_bettingId]].length <= i) amountCollected[partnerEvent[_bettingId]].push(0);
            uint256 amountToShareToWinners =  (
                (amountCollected[partnerEvent[_bettingId]][i] * (10000 - protocolInfo[_bettingId].adminShare))
            ) / 10000;
            // Initializes the amount to withdraw to treasury
            countWinnersPerBracket[_bettingId][i] = new uint[](1);
            tokenPerBracket[_bettingId][i] = new uint[](1);

            if (numberTicketsPerBettingId[_bettingId][_finalNumbers[_fIdx]].length <= i) {
                amountToWithdrawToTreasury = amountToShareToWinners;
            } else {
                countWinnersPerBracket[_bettingId][i][0] = numberTicketsPerBettingId[_bettingId][_finalNumbers[_fIdx]][i];
                tokenPerBracket[_bettingId][i][0] = amountToShareToWinners;
            }
            finalNumbers2[_bettingId].push(keccak256(abi.encodePacked(_finalNumbers[_fIdx])));
            
            status[_bettingId][i] = BettingStatus.Claimable;
            amountToWithdrawToTreasury += (amountCollected[partnerEvent[_bettingId]][i] - amountToShareToWinners);
            
            // // Transfer token to admin address
            // if (amountToWithdrawToTreasury > 0) {
                erc20(protocolInfo[_bettingId].token).approve(helper, amountToWithdrawToTreasury);
                IBetting(helper).notifyFees(protocolInfo[_bettingId].token, amountToWithdrawToTreasury);
            // }
            
            IBetting(helper).emitBettingResultsIn2(_bettingId, i, msg.sender, _finalNumbers[_fIdx++]);
        }
        // Update internal statuses for lottery
        nextToSet[_bettingId] += _finalNumbers.length;
    }

    function updatePaymentCredits(address _user, uint _bettingId, uint _credit) external {
        require(msg.sender == IContract(contractAddress).bettingHelper());
        paymentCredits[_user][_bettingId] += _credit;
    }

    /**
     * @notice Calculate rewards for a given ticket
     * @param _bettingId: lottery id
     * @param _ticketId: ticket id
     * @param _bracket: bracket for the ticketId to verify the claim and calculate rewards
     */
    function calculateRewardsForTicketId(
        uint _bettingId,
        uint _ticketId,
        uint _bracket
    ) public view returns (uint256) {
        if (protocolInfo[_bettingId].alphabetEncoding) {
            return keccak256(abi.encodePacked(tickets[_ticketId].letter)) == finalNumbers2[_bettingId][tickets[_ticketId].period]
            ? tokenPerBracket[_bettingId][tickets[_ticketId].period][_bracket] 
            : 0;
        }
        // Retrieve the user number combination from the ticketId
        // uint winningTicketNumber = finalNumbers[_bettingId][tickets[_ticketId].period];
        // uint userNumber = tickets[_ticketId].number;
        // Apply transformation to verify the claim provided by the user is true
        uint transformedWinningNumber = masks[_bettingId] + (finalNumbers[_bettingId][tickets[_ticketId].period] % (uint(10)**(_bracket + 1)));

        uint transformedUserNumber = masks[_bettingId] + (tickets[_ticketId].number % (uint(10)**(_bracket + 1)));

        // Confirm that the two transformed numbers are the same, if not throw
        // if (transformedWinningNumber == transformedUserNumber) {
            return transformedWinningNumber == transformedUserNumber
            ? tokenPerBracket[_bettingId][tickets[_ticketId].period][_bracket]
            : 0;
        // } else {
        //     return 0;
        // }
    }

    /**
     * @notice Calculate final price for bulk of tickets
     * @param _numberTickets: number of tickets purchased
     */
    function _calculateTotalPriceForBulkTickets(
        uint256 _numberTickets,
        uint256 _bettingId,
        address _user
    ) internal returns (uint256 _price) {
        uint256 _discountDivisor = protocolInfo[_bettingId].discountDivisor;
        _price = (protocolInfo[_bettingId].pricePerTicket * _numberTickets * (_discountDivisor + 1 - _numberTickets)) / _discountDivisor;
        if (paymentCredits[_user][_bettingId] > _price) {
            paymentCredits[_user][_bettingId] -= _price;
        } else {
            _price -= paymentCredits[_user][_bettingId];
        }
    }

    function deleteProtocol (uint _protocolId) public onlyAdmin {
        delete protocolInfo[_protocolId];
        IBetting(helper).emitDeleteProtocol(_protocolId);
    }

    function withdraw(address _token, uint _amount) external onlyAdmin lock {
        require(pendingRevenue[_token] >= _amount && collectionId > 0);
        if (_amount == 0) {
            _amount = pendingRevenue[_token];
            pendingRevenue[_token] = 0;
        } else {
            pendingRevenue[_token] -= _amount;
        }
        address businessGauge = IMarketPlace(IContract(contractAddress).businessGaugeFactory())
        .hasGauge(collectionId);
        IERC20(_token).safeTransfer(businessGauge, _amount);
        
        // IBetting(helper).emitWithdraw(msg.sender, _token, _amount);
    }

    function userWithdraw(uint _ticketId) external lock {
        require(msg.sender == tickets[_ticketId].owner);
        tickets[_ticketId].owner = address(0x0);
        IBetting(_minter()).burn(_ticketId);
        address _token = protocolInfo[partnerEvent[tickets[_ticketId].bettingId]].token;
        uint _rewards = tickets[_ticketId].rewards;
        tickets[_ticketId].rewards = 0;
        IERC20(_token).safeTransfer(msg.sender, _rewards);
        
        // IBetting(helper).emitWithdraw(msg.sender, _token, tickets[_ticketId].rewards);
    }

    function withdrawReferrerFee(address _token) external lock {
        uint _pendingReward = pendingReferrerFee[msg.sender][_token];
        require(pendingRevenue[_token] >= _pendingReward);
        pendingReferrerFee[msg.sender][_token] = 0;
        pendingRevenue[_token] -= _pendingReward;
        IERC20(_token).safeTransfer(msg.sender, _pendingReward);

        // IBetting(helper).emitWithdraw(msg.sender, _token, _pendingReward);
    }
}

contract BettingHelper {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct Time {
        uint times;
        uint lastCalled;
    }
    mapping(address => uint) public times;
    mapping(address => uint) public callIntervals;
    mapping(address => address) public partnerPaywall;
    mapping(address => mapping(address => Time)) public borrowedTime;
    
    uint private _maxAdminShare = 5000;
    mapping(address => bool) public maxChargeContracts;
    uint private _tradingFee = 100;
    EnumerableSet.AddressSet private gauges;
    address public contractAddress;
    mapping(address => uint) public treasuryFees;
    mapping(address => uint) public addressToProfileId;
    mapping(address => bool) public noChargeContracts;
    mapping(address => BettingCredit[]) public burnTokenForCredit;
    mapping(address => address) public uriGenerator;
    mapping(uint => uint) public pricePerAttachMinutes;
    mapping(uint => mapping(string => EnumerableSet.UintSet)) private excludedContents;

    event DeleteProtocol(uint indexed protocolId, address betting);
    event Withdraw(address indexed from, address betting, address token, uint amount);
    event UpdateMiscellaneous(
        uint idx, 
        uint bettingId, 
        string paramName, 
        string paramValue, 
        uint paramValue2, 
        uint paramValue3, 
        address sender,
        address paramValue4,
        string paramValue5
    );
    event UpdateProtocol(
        address betting,
        uint currentBettingId,
        uint startTime,
        address token,
        string action,
        uint adminShare,
        uint referrerShare,
        uint bracketDuration,
        uint pricePerTicket,
        uint discountDivisor,
        uint[] rewardsBreakdown,
        string media,
        string description
    );
    event CreateBetting(address betting, address _user, uint profileId);
    event DeleteBetting(address betting);
    event InjectFunds(
        address betting,
        address user,
        uint bettingId,
        uint period,
        uint amount
    );
    event TicketsPurchase(
        address betting,
        address user,
        uint bettingId,
        uint period,
        uint amount,
        uint ticketId,
        uint ticketNumber,
        string ticketNumber2
    );
    event TicketsClaim(
        address betting,
        address token, 
        uint rewardForTicketId, 
        uint bettingId, 
        uint ticketNumber
    );
    event BettingResultsIn(
        address betting,
        uint bettingId,
        uint period,
        address auditor,
        uint finalNumber
    );
    event BettingResultsIn2(
        address betting,
        uint bettingId,
        uint period,
        address auditor,
        string finalNumber
    );
    event CloseBetting(
        address betting,
        uint bettingId,
        uint period
    );

    // simple re-entrancy check
    uint internal _unlocked = 1;
    modifier lock() {
        require(_unlocked == 1);
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    function burnTokenForCreditLength(address _betting) external view returns(uint) {
        return burnTokenForCredit[_betting].length;
    }

    function updateBurnTokenForCredit(
        address _token,
        address _betting,
        address _checker,
        address _destination,
        uint _bettingId,
        uint _discount, 
        uint __collectionId,
        bool _clear,
        string memory _item
    ) external {
        require(IAuth(_betting).isAdmin(msg.sender));
        if(_clear) delete burnTokenForCredit[_betting];
        burnTokenForCredit[_betting].push(BettingCredit({
            token: _token,
            item: _item,
            checker: _checker,
            discount: _discount,
            bettingId: _bettingId,
            destination: _destination,
            collectionId: __collectionId
        }));
    }

    function burnForCredit(
        address _betting,
        uint _position, 
        uint256 _number  // tokenId in case of NFTs and amount otherwise 
    ) external {
        address _destination = burnTokenForCredit[_betting][_position].destination == address(this)
        ? msg.sender : burnTokenForCredit[_betting][_position].destination;
        uint credit;
        if (burnTokenForCredit[_betting][_position].checker == address(0x0)) { //FT
            IERC20(burnTokenForCredit[_betting][_position].token)
            .safeTransferFrom(msg.sender, _destination, _number);
            credit = burnTokenForCredit[_betting][_position].discount * _number / 10000;
        } else { //NFT
            uint _times = IMarketPlace(burnTokenForCredit[_betting][_position].checker).verifyNFT(
                _number,  
                burnTokenForCredit[_betting][_position].collectionId,
                burnTokenForCredit[_betting][_position].item
            );
            IERC721(burnTokenForCredit[_betting][_position].token)
            .transferFrom(msg.sender, _destination, _number);
            credit = burnTokenForCredit[_betting][_position].discount * _times;
        }
        IBetting(_betting).updatePaymentCredits(
            msg.sender,
            burnTokenForCredit[_betting][_position].bettingId,
            credit
        );
    }
    
    function onERC721Received(address,address,uint256,bytes memory) public virtual returns (bytes4) {
        return this.onERC721Received.selector; 
    }
    
    function updateMembershipParams(
        address _betting, 
        address _partnerPaywall, 
        uint _times, 
        uint _callIntervals
    ) external {
        require(IAuth(_betting).isAdmin(msg.sender));
        times[_betting] = _times;
        callIntervals[_betting] = _callIntervals;
        partnerPaywall[_betting] = _partnerPaywall;
    }

    function updateMaxChargeContracts(address _contract, bool _add) external {
        require(msg.sender == IAuth(contractAddress).devaddr_());
        maxChargeContracts[_contract] = _add;
    }

    function maxAdminShare() external view returns(uint) {
        if (maxChargeContracts[msg.sender]) {
            return 10000;
        }
        return _maxAdminShare;
    }

    function updateMaxAdminShare(uint _newMax) external {
        require(msg.sender == IAuth(contractAddress).devaddr_());
        _maxAdminShare = _newMax;
    }

    function checkMembership(address user) external {
        require(gauges.contains(msg.sender), "BH1");
        require(IAuth(msg.sender).isAdmin(user) || borrowedTime[msg.sender][user].times < times[msg.sender], "BH2");
        if (times[msg.sender] > 0 && borrowedTime[msg.sender][user].lastCalled + callIntervals[msg.sender] < block.timestamp) {
            borrowedTime[msg.sender][user].times += 1;
            borrowedTime[msg.sender][user].lastCalled = block.timestamp;
        }
    }

    function confirmSubscription(address betting, uint _nfticketId, string memory _productId) external {
        if (IMarketPlace(partnerPaywall[betting]).ongoingSubscription(msg.sender, _nfticketId, _productId)) {
            borrowedTime[betting][msg.sender].times = times[betting];
        }
    }

    function _trustBounty() internal view returns(address) {
        return IContract(contractAddress).trustBounty();
    }

    function setContractAddress(address _contractAddress) external {
        require(contractAddress == address(0x0) || IAuth(contractAddress).devaddr_() == msg.sender, "NT2");
        contractAddress = _contractAddress;
    }

    function setContractAddressAt(address _betting) external {
        IMarketPlace(_betting).setContractAddress(contractAddress);
    }

    function updateNoChargeContracts(address _contract, bool _add) external {
        require(msg.sender == IAuth(contractAddress).devaddr_());
        noChargeContracts[_contract] = _add;
    }

    function tradingFee() external view returns(uint) {
        if (noChargeContracts[msg.sender]) return 0;
        return _tradingFee;
    }

    function updateTradingFee(uint __tradingFee) external {
        require(msg.sender == IAuth(contractAddress).devaddr_(), "BH12");
        _tradingFee = __tradingFee;
    }

    function notifyFees(address _token, uint _fees) external {
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _fees);
        treasuryFees[_token] += _fees;
    }

    function verifyNFT(uint _tokenId, uint _collectionId, string memory item) external view returns(uint) {
        address minter = IContract(contractAddress).bettingMinter();
        if (
            IBetting(IBetting(minter).tokenIdToBetting(_tokenId)).collectionId() == _collectionId
        ) {
            return 1;
        }
        return 0;
    }

    function buyWithContract(
        address _collection, 
        address _user, 
        address _referrer, 
        string memory _period, 
        uint _bettingId, 
        uint _identityTokenId, 
        uint[] calldata _ticketNumbers,
        string[] calldata _ticketNumbers2
    ) external {
        require(gauges.contains(_collection));
        require(IValuePool(IContract(contractAddress).valuepoolHelper()).isGauge(msg.sender));
        IBetting(_collection).buyWithContract(
            _bettingId,
            _user, 
            _referrer, 
            _identityTokenId,
            st2num(_period),
            _ticketNumbers,
            _ticketNumbers2
        );
    }

    function st2num(string memory numString) internal pure returns(uint) {
        uint  val=0;
        bytes   memory stringBytes = bytes(numString);
        for (uint  i =  0; i<stringBytes.length; i++) {
            uint exp = stringBytes.length - i;
            bytes1 ival = stringBytes[i];
            uint8 uval = uint8(ival);
           uint jval = uval - uint(0x30);
   
           val +=  (uint(jval) * (10**(exp-1))); 
        }
      return val;
    }

    function getAllBettings(uint _start) external view returns(address[] memory bettings) {
        bettings = new address[](gauges.length() - _start);
        for (uint i = _start; i < gauges.length(); i++) {
            bettings[i] = gauges.at(i);
        }    
    }

    function isGauge(address _betting) external view returns(bool) {
        return gauges.contains(_betting);
    }
    
    function updateGauge(
        address _last_gauge,
        address _user,
        uint _profileId
    ) external {
        require(msg.sender == IContract(contractAddress).bettingFactory(), "BH3");
        require(IProfile(IContract(contractAddress).profile()).addressToProfileId(_user) == _profileId && _profileId > 0, "BH4");
        gauges.add(_last_gauge);
        addressToProfileId[_last_gauge] = _profileId;
        emit CreateBetting(_last_gauge, _user, _profileId);
    }
    
    function deleteBetting(address _betting) external {
        require(msg.sender == IAuth(contractAddress).devaddr_() || IAuth(_betting).isAdmin(msg.sender));
        gauges.remove(_betting);
        emit DeleteBetting(_betting);
    }
    
    function emitBettingResultsIn(uint _bettingId, uint _period, address _auditor, uint _finalNumber) external {
        require(gauges.contains(msg.sender));
        emit BettingResultsIn(
            msg.sender,
            _bettingId,
            _period,
            _auditor,
            _finalNumber
        );
    }

    function emitBettingResultsIn2(uint _bettingId, uint _period, address _auditor, string memory _finalNumber) external {
        require(gauges.contains(msg.sender));
        emit BettingResultsIn2(
            msg.sender,
            _bettingId,
            _period,
            _auditor,
            _finalNumber
        );
    }
    
    function emitCloseBetting(uint _bettingId, uint _period) external {
        require(gauges.contains(msg.sender));
        emit CloseBetting(msg.sender, _bettingId, _period);
    }
    
    function emitInjectFunds(
        address _user,
        uint _bettingId,
        uint _amount,
        uint _period
    ) external {
        require(gauges.contains(msg.sender));
        emit InjectFunds(
            msg.sender,
            _user,
            _bettingId,
            _amount,
            _period
        );
    }

    function emitTicketsPurchase(
        address _user,
        uint _bettingId,
        uint _amount,
        uint _ticketId,
        uint _ticketNumber,
        string memory _ticketNumber2,
        uint _period
    ) external {
        require(gauges.contains(msg.sender));
        emit TicketsPurchase(
            msg.sender,
            _user,
            _bettingId,
            _period,
            _amount,
            _ticketId,
            _ticketNumber,
            _ticketNumber2
        );
    }

    function emitTicketsClaim(
        address _token,
        uint _rewardForTicketId, 
        uint _bettingId, 
        uint _ticketId
    ) external {
        require(gauges.contains(msg.sender));
        emit TicketsClaim(
            msg.sender,
            _token, 
            _rewardForTicketId, 
            _bettingId, 
            _ticketId
        );
    }

    function emitWithdraw(address from, address token, uint amount) external {
        require(gauges.contains(msg.sender));
        emit Withdraw(from, msg.sender, token, amount);
    }

    function emitDeleteProtocol(uint protocolId) external {
        require(gauges.contains(msg.sender));
        emit DeleteProtocol(protocolId, msg.sender);
    }

    function emitUpdateMiscellaneous(
        uint _idx, 
        uint _bettingId, 
        string memory paramName, 
        string memory paramValue, 
        uint paramValue2, 
        uint paramValue3,
        address paramValue4,
        string memory paramValue5
    ) external {
        emit UpdateMiscellaneous(
            _idx, 
            _bettingId, 
            paramName, 
            paramValue, 
            paramValue2, 
            paramValue3, 
            msg.sender,
            paramValue4,
            paramValue5
        );
    }

    function emitUpdateProtocol(
        uint _currentBettingId,
        uint _startTime,
        address _token,
        string memory _action,
        uint[5] memory _values,
        uint[] memory _rewardsBreakdown,
        string memory _subjects,
        string memory _media,
        string memory _description
    ) external {
        require(gauges.contains(msg.sender));
        emit UpdateProtocol(
            msg.sender,
            _currentBettingId,
            _startTime,
            _token,
            _action,
            _values[0],
            _values[1],
            _values[2],
            _values[3],
            _values[4],
            _rewardsBreakdown,
            _media,
            _description
        );
        emit UpdateMiscellaneous(
            2,
            _currentBettingId,
            _subjects,
            "",
            0,
            0,
            msg.sender,
            address(this),
            ""
        );
    }

    function updateExcludedContent(string memory _tag, string memory _contentName, bool _add) external {
        uint _bettingProfileId = addressToProfileId[msg.sender];
        if (_add) {
            require(IContent(contractAddress).contains(_contentName), "BHH5");
            excludedContents[_bettingProfileId][_tag].add(uint(keccak256(abi.encodePacked(_contentName))));
        } else {
            excludedContents[_bettingProfileId][_tag].remove(uint(keccak256(abi.encodePacked(_contentName))));
        }
    }

    function getExcludedContents(uint _bettingProfileId, string memory _tag) public view returns(string[] memory _excluded) {
        _excluded = new string[](excludedContents[_bettingProfileId][_tag].length());
        for (uint i = 0; i < _excluded.length; i++) {
            _excluded[i] = IContent(contractAddress).indexToName(excludedContents[_bettingProfileId][_tag].at(i));
        }
    }

    function updatePricePerAttachMinutes(uint _pricePerAttachMinutes) external {
        uint _bettingProfileId = addressToProfileId[msg.sender];
        pricePerAttachMinutes[_bettingProfileId] = _pricePerAttachMinutes;
    }

    function updateUriGenerator(address _betting, address _uriGenerator) external {
        require(IAuth(_betting).isAdmin(msg.sender), "BHH8");
        uriGenerator[_betting] = _uriGenerator;
    }

    function emitAddSponsor(
        uint _bettingProfileId, 
        uint _currentMediaIdx,
        address _sponsor, 
        string memory _tag, 
        string memory _message
    ) external {
        require(IContract(contractAddress).bettingMinter() == msg.sender);
        emit UpdateMiscellaneous(
            2, 
            _bettingProfileId, 
            _tag,
            _message,
            0, 
            _currentMediaIdx, 
            msg.sender,
            _sponsor,
            ""
        );
    }

    function withdrawFees(address _token) external returns(uint _amount) {
        require(msg.sender == IAuth(contractAddress).devaddr_(), "BH13");
        _amount = treasuryFees[_token];
        IERC20(_token).safeTransfer(msg.sender, _amount);
        treasuryFees[_token] = 0;
        return _amount;
    }
}

contract BettingMinter is ERC721Pausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    struct ScheduledMedia {
        uint amount;
        uint active_period;
        string message;
    }
    uint seed = (block.timestamp + block.difficulty) % 100;
    mapping(uint => ScheduledMedia) public scheduledMedia;
    mapping(uint => uint) public pendingRevenue;
    mapping(uint => mapping(string => EnumerableSet.UintSet)) private _scheduledMedia;
    uint internal minute = 3600; // allows minting once per week (reset every Thursday 00:00 UTC)
    uint private currentMediaIdx = 1;
    uint private maxNumMedia = 2;
    mapping(uint => mapping(string => bool)) private tagRegistrations;
    mapping(uint => string) public tags;
    mapping(uint => address) public tokenIdToBetting;
    uint private tokenId = 1;
    address private contractAddress;
    address private valuepoolAddress;
    uint public treasury;
    uint public valuepool;
    
    constructor() ERC721("Betting", "BettingTicket") {}

    // simple re-entrancy check
    uint internal _unlocked = 1;
    modifier lock() {
        require(_unlocked == 1);
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    function updateValuepool(address _valuepoolAddress) external {
        require(IAuth(contractAddress).devaddr_() == msg.sender);
        valuepoolAddress = _valuepoolAddress;
    }
    
    function _helper() internal view returns(address) {
        return IContract(contractAddress).bettingHelper();
    }

    function mint(address _to) external returns(uint) {
        require(IBetting(_helper()).isGauge(msg.sender));
        _safeMint(_to, tokenId, msg.data);
        tokenIdToBetting[tokenId] = msg.sender;
        return tokenId++;
    }

    function burn(uint _tokenId) external {
        require(ownerOf(_tokenId) == msg.sender || IBetting(_helper()).isGauge(msg.sender));
        _burn(_tokenId);
        delete tokenIdToBetting[_tokenId];
    }

    function updateTags(string memory _tag) external {
        uint _bettingProfileId = IProfile(_helper()).addressToProfileId(msg.sender);
        tags[_bettingProfileId] = _tag;
    }

    function _getMedia(uint _tokenId) internal view returns(string[] memory _media) {
        address betting = tokenIdToBetting[_tokenId];
        uint _bettingProfileId = IProfile(_helper()).addressToProfileId(betting);
        string memory _tag = tags[_bettingProfileId];
        _bettingProfileId = tagRegistrations[_bettingProfileId][_tag] ? 1 : _bettingProfileId;
        uint _length = _scheduledMedia[_bettingProfileId][_tag].length();
        _media = new string[](Math.min(maxNumMedia, _length+1));
        uint randomHash = uint(seed + block.timestamp + block.difficulty);
        for (uint i = 0; i < Math.min(maxNumMedia, _length); i++) {
            _media[i] = scheduledMedia[_scheduledMedia[_bettingProfileId][_tag].at(randomHash++ % _length)].message;
        }
        for (uint i = Math.min(maxNumMedia, _length); i < Math.min(maxNumMedia, _length+1); i++) {
            _media[i] = IBetting(betting).media(_tokenId);
        }
    }

    function getAllMedia(uint _start, uint _bettingProfileId, string memory _tag) external view returns(string[] memory _media) {
        _media = new string[](_scheduledMedia[_bettingProfileId][_tag].length() - _start);
        for (uint i = _start; i < _scheduledMedia[_bettingProfileId][_tag].length(); i++) {
            _media[i] = scheduledMedia[_scheduledMedia[_bettingProfileId][_tag].at(i)].message;
        }  
    }

    function updateTagRegistration(string memory _tag, bool _add) external {
        address bettingHelper = IContract(contractAddress).bettingHelper();
        uint _bettingProfileId = IProfile(bettingHelper).addressToProfileId(msg.sender);
        require(_bettingProfileId > 0);
        tagRegistrations[_bettingProfileId][_tag] = _add;
        IBetting(bettingHelper).emitUpdateMiscellaneous(
            1,
            _bettingProfileId,
            _tag,
            "",
            _add ? 1 : 0,
            0,
            address(0x0),
            ""
        );
    }

    function claimPendingRevenue() external lock {
        uint _bettingProfileId = IProfile(_helper()).addressToProfileId(msg.sender);
        IERC20(IContract(contractAddress).token()).safeTransfer(address(msg.sender), pendingRevenue[_bettingProfileId]);
        pendingRevenue[_bettingProfileId] = 0;
    }

    function sponsorTag(
        address _sponsor,
        address _betting,
        uint _numMinutes, 
        string memory _tag, 
        string memory _message
    ) external {
        address bettingHelper = IContract(contractAddress).bettingHelper();
        uint _bettingProfileId = IProfile(bettingHelper).addressToProfileId(_betting);
        require(IAuth(_sponsor).isAdmin(msg.sender));
        require(!ISponsor(_sponsor).contentContainsAny(IBetting(bettingHelper).getExcludedContents(_bettingProfileId, _tag)));
        uint _pricePerAttachMinutes = IBetting(bettingHelper).pricePerAttachMinutes(_bettingProfileId);
        require(_pricePerAttachMinutes > 0, "3");
        uint price = _numMinutes * _pricePerAttachMinutes;
        IERC20(IContract(contractAddress).token()).safeTransferFrom(address(msg.sender), address(this), price);
        uint valuepoolShare = IContract(contractAddress).valuepoolShare();
        uint adminShare = IContract(contractAddress).adminShare();
        valuepool += price * valuepoolShare / 10000;
        if (_bettingProfileId > 0) {
            treasury += price * adminShare / 10000;
            pendingRevenue[_bettingProfileId] += price * (10000 - adminShare - valuepoolShare) / 10000;
        } else {
            treasury += price * (10000 - valuepoolShare) / 10000;
        }
        scheduledMedia[currentMediaIdx] = ScheduledMedia({
            amount: _numMinutes,
            message: _message,
            active_period: block.timestamp + _numMinutes * 60
        });
        _scheduledMedia[_bettingProfileId][_tag].add(currentMediaIdx);
        IBetting(bettingHelper).emitAddSponsor(_bettingProfileId, currentMediaIdx++, _sponsor, _tag, _message);
    }

    function updateSponsorMedia(uint _bettingProfileId, string memory _tag) external {
        uint _length = _scheduledMedia[_bettingProfileId][_tag].length();
        uint _endIdx = maxNumMedia > _length ? 0 : _length - maxNumMedia;
        for (uint i = 0; i < _endIdx; i++) {
            uint _currentMediaIdx = _scheduledMedia[_bettingProfileId][_tag].at(i);
            if (scheduledMedia[_currentMediaIdx].active_period < block.timestamp) {
                _scheduledMedia[_bettingProfileId][_tag].remove(_currentMediaIdx);
            }
        }
    }

    function withdrawTreasury(address _token, uint _amount) external lock {
        address token = IContract(contractAddress).token();
        address devaddr_ = IAuth(contractAddress).devaddr_();
        _token = _token == address(0x0) ? token : _token;
        uint _price = _amount == 0 ? treasury : Math.min(_amount, treasury);
        if (_token == token) {
            treasury -= _price;
            IERC20(_token).safeTransfer(devaddr_, _price);
        } else {
            IERC20(_token).safeTransfer(devaddr_, erc20(_token).balanceOf(address(this)));
        }
    }

    function claimValuepoolRevenue() external {
        require(msg.sender == IAuth(contractAddress).devaddr_());
        IERC20(IContract(contractAddress).token()).safeTransfer(valuepoolAddress, valuepool);
        valuepool = 0;
    }

    function updateMaxNumMedia(uint _maxNumMedia) external {
        require(IAuth(contractAddress).devaddr_() == msg.sender);
        maxNumMedia = _maxNumMedia;
    }

    function setContractAddress(address _contractAddress) external {
        require(contractAddress == address(0x0) || IAuth(contractAddress).devaddr_() == msg.sender);
        contractAddress = _contractAddress;
    }

    function _getOptions(address _betting, uint _protocolId) public view returns(string[] memory optionNames, string[] memory optionValues) {
        (,,uint _paid, uint _rewards, uint _bettingId, uint _period,,) = IBetting(_betting).tickets(_protocolId);
        address token = IBetting(_betting).getToken(_protocolId);
        optionNames = new string[](8);
        optionValues = new string[](8);
        uint idx;
        optionNames[idx] = "BID";
        optionValues[idx++] = toString(IBetting(_helper()).addressToProfileId(_betting));
        // optionNames[idx] = "CID";
        // optionValues[idx++] = toString(IBetting(_betting).collectionId());
        optionNames[idx] = "EID";
        optionValues[idx++] = toString(_bettingId);
        // optionNames[idx] = "Period,Symbol,Decimals";
        optionValues[idx++] = string(abi.encodePacked(toString(_period), ",", IBetting(token).symbol(), ",", toString(uint(IBetting(token).decimals()))));
        optionNames[idx] = "Paid";
        optionValues[idx++] = toString(_paid);
        // optionNames[idx] = "Period";
        // optionValues[idx++] = toString(_period);
        optionNames[idx] =  "Rewards";
        optionValues[idx++] = toString(_rewards);
        // optionValues[idx++] = _claimed ? "Yes" : "No";
        optionValues[idx++] = IBetting(_betting).subjects(_bettingId);
        optionValues[idx++] = IBetting(_betting).getAction(_bettingId);
        optionNames[idx] = "Pick";
        optionValues[idx++] = IBetting(_betting).getLetter(_protocolId);
    }

    function tokenURI(uint _tokenId) public view virtual override returns (string memory output) {
        address _uriGenerator = IBetting(_helper()).uriGenerator(tokenIdToBetting[_tokenId]);
        if (_uriGenerator != address(0x0)) {
            output = IBetting(_uriGenerator).uri(_tokenId);
        } else {
            (string[] memory optionNames, string[] memory optionValues) = _getOptions(
                tokenIdToBetting[_tokenId], 
                _tokenId
            ); // max number = 12
            string[] memory _description = new string[](1);
            _description[0] = IBetting(tokenIdToBetting[_tokenId]).description(_tokenId); // max number = 1
            string[] memory _media = _getMedia(_tokenId); // max number = 2
            output = _constructTokenURI(_tokenId, _media, _description, optionNames, optionValues);
        }
    }

    function _constructTokenURI(uint _tokenId, string[] memory _media, string[] memory _description, string[] memory optionNames, string[] memory optionValues) public view returns(string memory) {
        return IMarketPlace(IContract(contractAddress).nftSvg()).constructTokenURI(
            _tokenId,
            tokenIdToBetting[_tokenId],
            IBetting(tokenIdToBetting[_tokenId]).getToken(_tokenId),
            ownerOf(_tokenId),
            address(0x0),
            _media.length > 0 ? _media : new string[](1),
            optionNames,
            optionValues,
            _description.length > 0 ? _description : new string[](1)
        );
    }

    function toString(uint value) internal pure returns (string memory) {
        // Inspired by OraclizeAPI's implementation - MIT license
        // https://github.com/oraclize/ethereum-api/blob/b42146b063c7d6ee1358846c198246239e9360e8/oraclizeAPI_0.4.25.sol

        if (value == 0) {
            return "0";
        }
        uint temp = value;
        uint digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}

contract BettingFactory {
    address private contractAddress;

    constructor(address _contractAddress) {
        contractAddress = _contractAddress;
    }

    function createGauge(uint _profileId, address _devaddr, address _oracle) external {
        address bettingHelper = IContract(contractAddress).bettingHelper();
        address last_gauge = address(new Betting(
            _devaddr,
            bettingHelper,
            _oracle,
            contractAddress
        ));
        IBetting(bettingHelper).updateGauge(
            last_gauge, 
            _devaddr, 
            _profileId
        );
    }
}