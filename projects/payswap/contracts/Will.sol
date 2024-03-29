// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "./Library.sol";

// Gauges are used to incentivize pools, they emit reward tokens over 7 days for staked LP tokens
contract WILL {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    address private devaddr_;
    address private helper;
    // string public media;
    mapping(address => uint) public totalProcessed;
    mapping(uint => mapping(address => uint)) public paidPayable;
    struct ProtocolInfo {
        uint createdAt;
        uint updatedAt;
        string ssid;
        string media;
        string description;
    }
    mapping(uint => address[]) public tokens;
    mapping(uint => uint[]) public percentages;
    mapping(uint => ProtocolInfo) public protocolInfo;
    mapping(address => NFTYPE) public tokenType;
    EnumerableSet.AddressSet private _allTokens;
    mapping(address => uint) public balanceOf; // tokens balances
    mapping(address => uint) public totalRemoved; // tokens balances
    uint private profileId;
    uint public collectionId;
    uint private updatePeriod = 86400 * 7 * 2;
    uint private activePeriod;
    uint private willWithdrawalActivePeriod;
    mapping(address => uint) public willActivePeriod;
    uint private willWithdrawalPeriod = 86400 * 7 * 26;
    uint private maxWithdrawableNow = 2500;
    uint private maxNFTWithdrawableNow = 1;
    bool public unlocked = false;
    address private contractAddress;
    address profile;
    // mapping(address => mapping(uint => uint)) public lockedBalance;
    mapping(uint => bool) public locked;

    constructor(
        address _devaddr,
        address _helper,
        address __contractAddress
    ) {
        profile = IContract(__contractAddress).profile();
        profileId = IProfile(profile).addressToProfileId(_devaddr);
        collectionId = IMarketPlace(IContract(__contractAddress).marketCollections()).addressToCollectionId(_devaddr);
        require(profileId > 0);
        helper = _helper;
        devaddr_ = _devaddr;
        contractAddress = __contractAddress;
    }

    // simple re-entrancy check
    uint internal _unlocked = 1;
    modifier lock() {
        require(_unlocked == 1);
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    modifier onlyAdmin() {
        require(IProfile(profile).addressToProfileId(msg.sender) == profileId);
        _;
    }

    function isAdmin(address _user) external view returns(bool) {
        return IProfile(profile).addressToProfileId(_user) == profileId;
    }

    function getParams() external view returns(uint,uint,uint,uint,uint,uint) {
        return (
            updatePeriod,
            activePeriod,
            maxWithdrawableNow,
            willWithdrawalPeriod,
            maxNFTWithdrawableNow,
            willWithdrawalActivePeriod
        );
    }

    function updateDev(address _devaddr) external onlyAdmin {
        profileId = IProfile(profile).addressToProfileId(_devaddr);
        collectionId = IMarketPlace(IContract(contractAddress).marketCollections()).addressToCollectionId(_devaddr);
        devaddr_ = _devaddr;
    }

    // function updateMedia(string memory _media) external onlyAdmin {
    //     // useful to leave message regarding decisions to make about your body after you die
    //     // or guidelines on decisions when you are not conscious to make them
    //     media = _media;
    // }

    function getProtocolInfo(uint _profileId, uint _position, uint _amount) external view returns(
        bool isNFT,
        uint value,
        address token,
        uint percentage,
        address[] memory _tokens,
        uint[] memory _percentages,
        string memory _media,
        string memory description
    ) {
        require(
            (unlocked && IProfile(profile).addressToProfileId(msg.sender) == _profileId) ||
            IProfile(profile).addressToProfileId(msg.sender) == profileId ||
            msg.sender == helper
        );
        token = tokens[_profileId][_position];
        isNFT = tokenType[token] != NFTYPE.not;
        value = tokenType[token] != NFTYPE.not ? balanceOf[token] : balanceOf[token] * percentages[_profileId][_position] / 10000;
        percentage = tokenType[token] != NFTYPE.not ? 10000 : percentages[_profileId][_position];
        if (tokenType[token] == NFTYPE.not && _amount > 0) {
            value = Math.min(_amount, value);
            percentage = value * 10000 / balanceOf[token];
        }
        _tokens = tokens[_profileId];
        _percentages = percentages[_profileId];
        _media = protocolInfo[_profileId].media;
        description = protocolInfo[_profileId].description;
    }
    
    function updateParameters(
        uint _profileId,
        uint _updatePeriod,
        uint _maxWithdrawableNow,
        uint _maxNFTWithdrawableNow,
        uint _willWithdrawalPeriod
    ) external onlyAdmin {
        if (activePeriod < block.timestamp) {
            updatePeriod = _updatePeriod;
            willWithdrawalPeriod = _willWithdrawalPeriod;
            maxWithdrawableNow = _maxWithdrawableNow;
            maxNFTWithdrawableNow = _maxNFTWithdrawableNow;
            activePeriod = block.timestamp + updatePeriod;
        }
        if (_profileId > 0) {
            profileId = IProfile(profile).addressToProfileId(msg.sender);
            require(IProfile(profile).addressToProfileId(msg.sender) > 0);
        }
        IWill(helper).emitUpdateParameters(
            _profileId,
            _updatePeriod,
            _maxWithdrawableNow,
            _maxNFTWithdrawableNow,
            _willWithdrawalPeriod
        );
    }
    
    function getAllTokens(uint _start) external view returns(
        address[] memory _tokens,
        uint[] memory balances,
        NFTYPE[] memory tokenTypes
    ) {
        _tokens = new address[](_allTokens.length() - _start);
        balances = new uint[](_allTokens.length() - _start);
        tokenTypes = new NFTYPE[](_allTokens.length() - _start);
        for (uint i = _start; i < _allTokens.length(); i++) {
            _tokens[i] = _allTokens.at(i);
            balances[i] = balanceOf[_tokens[i]];
            tokenTypes[i] = tokenType[_tokens[i]];
        }    
    }
    

    function addBalanceETH(address _from) external payable lock {
        IWETH(address(this)).deposit{value: msg.value}();
        addBalance(helper, _from, msg.value, NFTYPE.not);
    }

    function deposit() public payable returns (uint256) {}

    function addBalance(address _token, address _from, uint _value, NFTYPE _tokenType) public {
        if (_tokenType == NFTYPE.not) {
            if (_token != helper) {
               IERC20(_token).safeTransferFrom(_from, address(this), _value);
            }
        } else if (_tokenType == NFTYPE.erc721) {
            IERC721(_token).safeTransferFrom(_from, address(this), _value);
        } else {
            IERC1155(_token).safeTransferFrom(_from, address(this), _value, 1, msg.data);
        }
        tokenType[_token] = _tokenType;
        balanceOf[_token]+= _value;
        _allTokens.add(_token);
        IWill(helper).emitAddBalance(
            _token,
            _value,
            _tokenType
        );
    }

    function createLock(
        address _token, 
        address _ve, 
        uint _lockDuration, 
        uint _identityTokenId, 
        uint _amount
    ) external onlyAdmin {
        erc20(_token).approve(_ve, _amount);
        IValuePool(_ve).create_lock_for(
            _amount,
            _lockDuration,
            _identityTokenId,
            address(this)
        );
    }

    function updateAllowance(address _ve, address _to, bool _approve) external onlyAdmin {
        IWill(_ve).setApprovalForAll(_to, _approve);
    }

    function unLock(address _ve, uint _tokenId) external onlyAdmin {
        IValuePool(_ve).withdraw(_tokenId);
    }

    function updateActivePeriod(address _token) public onlyAdmin {
        if (block.timestamp >= willActivePeriod[_token]) {
            willActivePeriod[_token] = (block.timestamp + updatePeriod) / updatePeriod * updatePeriod;
            totalRemoved[_token] = 0;
        }
    }

    function removeBalance(address _token, uint _value) external onlyAdmin {
        // require(lockedBalance[_token][1] + _value <= balanceOf[_token]);
        updateActivePeriod(_token);
        require(totalRemoved[_token] + _value <= balanceOf[_token] * maxWithdrawableNow / 10000, "W2");
        if (tokenType[_token] == NFTYPE.not) {
            uint payswapFees = Math.min(
                _value * IWill(helper).tradingFee(true) / 10000, 
                IContract(contractAddress).cap(_token) > 0 
                ? IContract(contractAddress).cap(_token) : type(uint).max
            );
            if (_token != helper) {
                erc20(_token).approve(helper, payswapFees);
            } else {
                _safeTransfer(_token, helper, payswapFees);
            }
            IWill(helper).notifyFees(_token, payswapFees);
            _safeTransfer(_token, msg.sender, _value - payswapFees);
            totalRemoved[_token] += _value;
            if (balanceOf[_token] == _value) {
                delete tokenType[_token];
                _allTokens.remove(_token);
            }
            balanceOf[_token] -= _value;
            IWill(helper).emitRemoveBalance(
                _token,
                _value,
                NFTYPE.not
            );
        }
    }

    function removeNFTBalance(address _token, uint _value) external onlyAdmin {
        // require(lockedBalance[_token][_value] != _value);
        updateActivePeriod(address(this));
        require(tokenType[_token] != NFTYPE.not);
        require(totalRemoved[address(this)] < maxNFTWithdrawableNow);
        IWill(helper).notifyNFTFees(msg.sender);
        if (tokenType[_token] == NFTYPE.erc721) {
            IERC721(_token).safeTransferFrom(address(this), msg.sender, _value);
        } else {
            IERC1155(_token).safeTransferFrom(address(this), msg.sender, _value, 1, msg.data);
        }
        IWill(helper).emitRemoveBalance(
            _token,
            _value,
            tokenType[_token]
        );
        totalRemoved[address(this)] = 1;
        delete tokenType[_token];
        _allTokens.remove(_token);
        balanceOf[_token] = 0;
    }

    function onERC721Received(address,address,uint256,bytes memory) public virtual returns (bytes4) {
        return this.onERC721Received.selector; 
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public virtual returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function updateProtocol(
        uint _profileId,
        address _owner,
        address[] memory _tokens,
        uint[] memory _percentages,
        string memory _ssid,
        string memory _media,
        string memory _description
    ) external onlyAdmin {
        if(protocolInfo[_profileId].createdAt == 0) {
            require(_profileId > 0);
            protocolInfo[_profileId].createdAt = block.timestamp;
        }
        protocolInfo[_profileId].media = _media;
        protocolInfo[_profileId].ssid = _ssid;
        protocolInfo[_profileId].description = _description;
        protocolInfo[_profileId].updatedAt = block.timestamp;
        if (!locked[_profileId]) {
            tokens[_profileId] = _tokens;
            percentages[_profileId] = _percentages;
        }
        IWill(helper).emitUpdateProtocol(
            _profileId,
            _owner,
            _media,
            _description,
            _tokens,
            _percentages
        );
    }

    function deleteProtocol (uint _profileId) external onlyAdmin {
        require(!locked[_profileId]);
        delete protocolInfo[_profileId];
        IWill(helper).emitDeleteProtocol(_profileId);
    }

    function payInvoicePayable(uint _profileId, uint _position) external payable lock {
        uint __profileId = IProfile(profile).addressToProfileId(msg.sender);
        SSIData memory metadata = ISSI(IContract(contractAddress).ssi()).getSSID(__profileId);
        require(
            (__profileId == _profileId) || keccak256(abi.encodePacked(protocolInfo[_profileId].ssid)) == keccak256(abi.encodePacked(metadata.answer))
        );
        if (willWithdrawalActivePeriod <= block.timestamp && willWithdrawalActivePeriod != 0) { 
            unlocked = true;
            address token = tokens[_profileId][_position];
            uint _percentage = tokenType[token] == NFTYPE.not ? percentages[_profileId][_position] : 10000;
            uint duePayable = _percentage * balanceOf[token] / 10000 - paidPayable[_profileId][token];
            paidPayable[_profileId][token] += duePayable;
            uint payswapFees = tokenType[token] == NFTYPE.not ? Math.min(
                duePayable * IWill(helper).tradingFee(false) / 10000, 
                IContract(contractAddress).cap(token) > 0 
                ? IContract(contractAddress).cap(token) : type(uint).max
            ) : 0;

            if (tokenType[token] == NFTYPE.not) {
                uint value = duePayable - payswapFees;
                totalProcessed[token] += duePayable;
                if (token != helper) {
                    erc20(token).approve(helper, payswapFees);
                } else {
                    _safeTransfer(token, helper, payswapFees);
                }
                IWill(helper).notifyFees(token, payswapFees);
                _safeTransfer(token, msg.sender, value);
            } else if (tokenType[token] == NFTYPE.erc721) {
                IERC721(token).safeTransferFrom(address(this), msg.sender, duePayable);
            } else {
                IERC1155(token).safeTransferFrom(address(this), msg.sender, duePayable, 1, msg.data);
            }
            if (tokenType[token] != NFTYPE.not) {
                IWill(helper).notifyNFTFees(msg.sender);
            }
            IWill(helper).emitPayInvoicePayable(duePayable);
        } else {
            willWithdrawalActivePeriod = block.timestamp + willWithdrawalPeriod;
            IWill(helper).emitStartWillWithdrawalCountDown(_profileId);
        }
    }

    function updatePercentage(address _token, uint _profileId, uint _position, uint _percentage) external {
        require(msg.sender == helper && tokens[_profileId][_position] == _token, "W1");
        percentages[_profileId][_position] -= _percentage;
        locked[_profileId] = true;
    }

    function stopWillWithdrawalCountdown() external onlyAdmin {
        willWithdrawalActivePeriod = 0;
    }

    function _safeTransfer(address _token, address to, uint256 value) internal {
        if (_token == helper) {
            (bool success, ) = to.call{value: value}(new bytes(0));
            require(success);
        } else {
            (bool success, bytes memory data) =
            _token.call(abi.encodeWithSelector(erc20.transfer.selector, to, value));
            require(success && (data.length == 0 || abi.decode(data, (bool))));
        }
    }

    function noteWithdraw(address _to, address _token, uint _profileId, uint duePayable, uint payswapFees) external payable {
        require(msg.sender == helper);
        locked[_profileId] = false;
        if (tokenType[_token] == NFTYPE.not) {
            uint value = duePayable - payswapFees;
            totalProcessed[_token] += duePayable;
            if (_token != helper) {
                erc20(_token).approve(helper, payswapFees);
            } else {
                _safeTransfer(_token, helper, payswapFees);
            }
            _safeTransfer(_token, msg.sender, value);
        } else if (tokenType[_token] == NFTYPE.erc721) {
            IERC721(_token).safeTransferFrom(address(this), _to, duePayable);
        } else {
            IERC1155(_token).safeTransferFrom(address(this), _to, duePayable, 1, msg.data);
        }
    }
}

contract WILLNote is ERC721Pausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint tokenId = 1;
    EnumerableSet.AddressSet private gauges;
    address contractAddress;
    mapping(address => uint) public treasuryFees;
    mapping(address => EnumerableSet.AddressSet) private _whereIHaveMyMoney;
    uint private tradingFeeAdmin = 100;
    uint private tradingFeeUser = 100;
    uint public tradingNFTFee = 1e18;
    address public valuepoolAddress;
    struct InheritanceCheque {
        address will;
        address token;
        NFTYPE isNFT;
        uint profileId;
        uint percentage;
    }
    mapping(uint => InheritanceCheque) public notes;

    event PayInvoicePayable(address will, uint toPay);
    event DeleteProtocol(uint indexed protocolId, address will);
    event Withdraw(address indexed from, address will, uint amount);
    event TransferDueToNote(address will, uint protocolId, uint tokenId, uint percentage);
    event StartWillWithdrawalCountDown(address will, uint profileId);
    event ClaimTransferNote(uint tokenId);
    event UpdateMiscellaneous(
        uint idx, 
        uint willId, 
        string paramName, 
        string paramValue, 
        uint paramValue2, 
        uint paramValue3, 
        address sender,
        address paramValue4,
        string paramValue5
    );
    event AddBalance(
        address will,
        address token,
        uint value,
        NFTYPE tokenType
    );
    event RemoveBalance(
        address will,
        address token,
        uint value,
        NFTYPE tokenType
    );
    event CreateWILL(address will);
    event DeleteWILL(address will);
    event UpdateParameters(
        address will,
        uint profileId,
        uint updatePeriod,
        uint maxWithdrawableNow,
        uint maxNFTWithdrawableNow,
        uint willWithdrawalPeriod
    );
    event UpdateProtocol(
        address will,
        address owner,
        uint profileId,
        string media,
        string description,
        address[] tokens,
        uint[] percentages
    );

    constructor() ERC721("WILLProof", "WILLNFT")  {}

    // simple re-entrancy check
    uint internal _unlocked = 1;
    modifier lock() {
        require(_unlocked == 1);
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    function setContractAddress(address _contractAddress) external {
        require(contractAddress == address(0x0) || IAuth(contractAddress).devaddr_() == msg.sender);
        contractAddress = _contractAddress;
    }

    function tradingFee(bool _admin) public view returns(uint) {
        return _admin ? tradingFeeAdmin : tradingFeeUser;
    }

    fallback() external payable {}

    function updateParams(
        uint _tradingFeeAdmin, 
        uint _tradingFeeUser,
        uint _tradingNFTFee
    ) external {
        require(msg.sender == IAuth(contractAddress).devaddr_(), "BILLH12");
        tradingFeeAdmin = _tradingFeeAdmin;
        tradingFeeUser = _tradingFeeUser;
        tradingNFTFee = _tradingNFTFee;
    }
    
    function emitUpdateProtocol(
        uint _profileId,
        address _owner,
        string memory _media,
        string memory _description,
        address[] memory _tokens,
        uint[] memory _percentages
    ) external {
        emit UpdateProtocol(
            msg.sender,
            _owner,
            _profileId,
            _media,
            _description,
            _tokens,
            _percentages
        );
    }

    function transferDueToNotePayable(
        address _will,
        address _to, 
        address _token, 
        uint _profileId,
        uint _position,
        uint _percentage
    ) external lock {
        require(
            IProfile(IContract(contractAddress).profile()).addressToProfileId(msg.sender) == _profileId, 
            "WILLH7"
        );
        notes[tokenId] = InheritanceCheque({
            will: _will,
            token: _token,
            isNFT: IWill(_will).tokenType(_token),
            profileId: _profileId,
            percentage: _percentage
        });
        IWill(_will).updatePercentage(_token, _profileId, _position, _percentage);
        _safeMint(_to, tokenId, msg.data);
        emit TransferDueToNote(_will, _profileId, tokenId++, _percentage);
    }

    function claimPendingRevenueFromNote(uint _tokenId) external lock {
        require(ownerOf(_tokenId) == msg.sender, "BILLH10");
        require(IWill(notes[_tokenId].will).unlocked(), "BILLH11");

        if (notes[_tokenId].isNFT != NFTYPE.not) {
            notifyNFTFees(msg.sender);
        }
        address _token = notes[_tokenId].token;
        uint _percentage = notes[_tokenId].isNFT == NFTYPE.not ? notes[_tokenId].percentage : 10000;
        uint duePayable = _percentage * IWill(notes[_tokenId].will).balanceOf(_token) / 10000;
        uint payswapFees = notes[_tokenId].isNFT == NFTYPE.not ? Math.min(
            duePayable * tradingFeeUser / 10000, 
            IContract(contractAddress).cap(_token) > 0 
            ? IContract(contractAddress).cap(_token) : type(uint).max
        ) : 0;
        IWill(notes[_tokenId].will).noteWithdraw(
            address(msg.sender), 
            _token, 
            notes[_tokenId].profileId, 
            duePayable,
            payswapFees
        );
        if (_token != address(this)) {
            IERC20(_token).safeTransferFrom(notes[_tokenId].will, address(this), payswapFees);
        } 
        treasuryFees[_token] += payswapFees;
        delete notes[_tokenId];
        _burn(_tokenId);
        emit ClaimTransferNote(_tokenId);
    }

    function updateValuepool(address _valuepoolAddress) external {
        require(IAuth(contractAddress).devaddr_() == msg.sender, "BILLHH4");
        valuepoolAddress = _valuepoolAddress;
    }

    function buyWithContract(
        address _will,
        address _user,
        address _token,
        string memory _tokenId,
        uint _amount,
        uint[] memory _protocolIds   
    ) external {
        require(IValuePool(IContract(contractAddress).valuepoolHelper()).isGauge(msg.sender));
        require(IWill(IContract(contractAddress).willNote()).isGauge(_will), "WHHH1");
        NFTYPE _tokenType = IWill(_will).tokenType(_token);
        if (_tokenType != NFTYPE.not) {
            IERC721(_token).setApprovalForAll(_will, true);
        } else {
            erc20(_token).approve(_will, _amount);
        }
        IWill(_will).addBalance(_protocolIds, _amount, _tokenType);
    }

    function notifyFees(address _token, uint _fees) external {
        require(gauges.contains(msg.sender), "BILLH2");       
        if (_token != address(this)) {
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _fees);
        } 
        treasuryFees[_token] += _fees;
    }

    function notifyNFTFees(address _user) public {
        require(gauges.contains(msg.sender), "BILLH02");        
        address _token = IContract(contractAddress).token();
        IERC20(_token).safeTransferFrom(_user, address(this), tradingNFTFee);
        treasuryFees[_token] += tradingNFTFee;
    }

    function getAllWills(uint _start) external view returns(address[] memory wills) {
        wills = new address[](gauges.length() - _start);
        for (uint i = _start; i < gauges.length(); i++) {
            wills[i] = gauges.at(i);
        }    
    }

    function isGauge(address _will) external view returns(bool) {
        return gauges.contains(_will);
    }
    
    function updateGauge(address _last_gauge) external {
        require(msg.sender == IContract(contractAddress).willFactory(), "BILLH3");
        gauges.add(_last_gauge);
        emit CreateWILL(_last_gauge);
    }
    
    function deleteWILL(address _will) external {
        require(msg.sender == IAuth(contractAddress).devaddr_() || IAuth(_will).isAdmin(msg.sender));
        gauges.remove(_will);
        emit DeleteWILL(_will);
    }

    function emitPayInvoicePayable(uint _toPay) external {
        require(gauges.contains(msg.sender));
        emit PayInvoicePayable(msg.sender, _toPay);
    }

    function emitAddBalance(address token, uint value, NFTYPE tokenType) external {
        require(gauges.contains(msg.sender));
        emit AddBalance(msg.sender, token, value, tokenType);
    }

    function emitRemoveBalance(address token, uint value, NFTYPE tokenType) external {
        require(gauges.contains(msg.sender));
        emit RemoveBalance(msg.sender, token, value, tokenType);
    }

    function emitUpdateParameters(
        uint _profileId,
        uint _updatePeriod,
        uint _maxWithdrawableNow,
        uint _maxNFTWithdrawableNow,
        uint _willWithdrawalPeriod
    ) external {
        require(gauges.contains(msg.sender));
        emit UpdateParameters(
            msg.sender,
            _profileId,
            _updatePeriod,
            _maxWithdrawableNow,
            _maxNFTWithdrawableNow,
            _willWithdrawalPeriod
        );
    }
    
    function emitStartWillWithdrawalCountDown(uint _profileId) external {
        require(gauges.contains(msg.sender));
        emit StartWillWithdrawalCountDown(msg.sender, _profileId);
    }

    function emitDeleteProtocol(uint _profileId) external {
        require(gauges.contains(msg.sender));
        emit DeleteProtocol(_profileId, msg.sender);
    }

    function emitUpdateMiscellaneous(
        uint _idx, 
        uint _willId, 
        string memory paramName, 
        string memory paramValue, 
        uint paramValue2, 
        uint paramValue3,
        address paramValue4,
        string memory paramValue5
    ) external {
        emit UpdateMiscellaneous(
            _idx, 
            _willId, 
            paramName, 
            paramValue, 
            paramValue2, 
            paramValue3, 
            msg.sender,
            paramValue4,
            paramValue5
        );
    }

    function withdrawFees(address _token, address to) external payable returns(uint _amount) {
        require(msg.sender == IAuth(contractAddress).devaddr_(), "BILLH13");
        _amount = treasuryFees[_token];
        if (_token == address(this)) {
            (bool success, ) = to.call{value: _amount}(new bytes(0));
            require(success, "T42");
        } else {
            IERC20(_token).safeTransfer(to, _amount);
        }
        treasuryFees[_token] = 0;
        return _amount;
    }

    function updateWhereIHaveMyMoney(address _will, address _contractAddress, bool _add) external {
        require(IAuth(_will).isAdmin(msg.sender));
        if (_add) {
            _whereIHaveMyMoney[_will].add(_contractAddress);
        } else {
            _whereIHaveMyMoney[_will].remove(_contractAddress);
        }
    }

    function getAllMoney(address _will, uint _start) external view returns(address[] memory contracts) {
        require(IWill(_will).unlocked());
        contracts = new address[](_whereIHaveMyMoney[_will].length() - _start);
        for (uint i = _start; i < _whereIHaveMyMoney[_will].length(); i++) {
            contracts[i] = _whereIHaveMyMoney[_will].at(i);
        }    
    }

    function _constructTokenURI(uint _tokenId, address _token, string[] memory description, string[] memory optionNames, string[] memory optionValues) internal view returns(string memory) {
        return IMarketPlace(IContract(contractAddress).nftSvg()).constructTokenURI(
            _tokenId,
            _token,
            ownerOf(_tokenId),
            ownerOf(_tokenId),
            address(0x0),
            IValuePool(IContract(contractAddress).valuepoolHelper2()).getMedia(valuepoolAddress,_tokenId),
            optionNames,
            optionValues,
            description
        );
    }

    function tokenURI(uint _tokenId) public override view returns (string memory output) {
        uint idx;
        string[] memory optionNames = new string[](5);
        string[] memory optionValues = new string[](5);
        optionValues[idx++] = toString(_tokenId);
        optionNames[idx] = "PID";
        optionValues[idx++] = toString(notes[_tokenId].profileId);
        optionNames[idx] = "Percentage";
        optionValues[idx++] = string(abi.encodePacked(toString(notes[_tokenId].percentage / 100), "%"));
        optionNames[idx] = "isNFT";
        optionValues[idx++] = notes[_tokenId].isNFT != NFTYPE.not ? "Yes" : "No";
        optionNames[idx] = "Unlocked";
        optionValues[idx++] = IWill(notes[_tokenId].will).unlocked() ? "Yes" : "No";
        string[] memory _description = new string[](1);
        _description[0] = "This cheque gives you access to the due amount from the will contract";
        output = _constructTokenURI(
            _tokenId, 
            notes[_tokenId].token,
            _description,
            optionNames, 
            optionValues 
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

contract WILLFactory {
    address contractAddress;

    constructor(address _contractAddress) {
        contractAddress = _contractAddress;
    }

    function createGauge(address _devaddr) external {
        address _willNote = IContract(contractAddress).willNote();
        address last_gauge = address(new WILL(
            _devaddr,
            _willNote,
            contractAddress
        ));
        IWill(_willNote).updateGauge(last_gauge);
    }
}