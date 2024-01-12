// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "./Library.sol";

contract ReferralVoter {

    uint internal constant DURATION = 7 days; // rewards are released over 7 days
    address public contractAddress;

    mapping(address => uint) public totalWeight; // total voting weight

    mapping(address => uint[]) public pools; // all pools viable for incentives
    mapping(uint => mapping(address => address)) public gauges; // pool => gauge
    mapping(address => uint) public poolForGauge; // gauge => pool
    mapping(address => address) public bribes; // gauge => bribe
    mapping(uint => mapping(address => uint)) public weights; // pool => weight
    mapping(uint => mapping(string => uint)) public votes; // nft => pool => votes
    mapping(uint => mapping(address => uint)) public usedWeights;  // nft => total voting weight of user
    mapping(address => bool) public isGauge;

    event GaugeCreated(uint indexed pool, address _ve, address gauge, address creator, address bribe);
    event Voted(uint indexed _collectionId, uint tokenId, uint weight, address _ve, address voter);
    event Abstained(uint tokenId, uint _collectionId, address _ve, uint weight);
    event Deposit(address indexed lp, address indexed gauge, uint tokenId, uint amount);
    event Withdraw(address indexed lp, address indexed gauge, uint tokenId, uint amount);
    event NotifyReward(address indexed sender, address indexed ve, uint amount);
    event DistributeReward(address indexed sender, address indexed gauge, uint amount);
    event DeactivateGauge(uint indexed collectionId, address _ve);
    event UpdateMiscellaneous(
        uint idx, 
        uint collectionId, 
        string paramName, 
        string paramValue, 
        uint paramValue2, 
        uint paramValue3, 
        address sender,
        address paramValue4,
        string paramValue5
    );

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

    function deactivateGauge(address _ve) external {
        emit DeactivateGauge(IMarketPlace(
            IContract(contractAddress).marketCollections()
        ).addressToCollectionId(msg.sender), _ve);
    }
    
    // function _reset(uint _tokenId, uint _profileId, address _ve) internal {
    //     string memory cid = string(abi.encodePacked(_profileId, _ve));
    //     uint _votes = votes[_tokenId][cid];
    //     if (_votes != 0) {
    //         _updateFor(gauges[_profileId][_ve], _ve);
    //         weights[_profileId][_ve] -= _votes;
    //         IReferralVoter(bribes[gauges[_profileId][_ve]]).withdraw(_votes, _tokenId);
    //         votes[_tokenId][cid] -= _votes;
    //         emit Abstained(_tokenId, _profileId, _ve, _votes);
    //     }
    //     totalWeight[_ve] -= Math.min(totalWeight[_ve], _votes);
    //     usedWeights[_tokenId][_ve] -= Math.min(usedWeights[_tokenId][_ve], _votes);
    // }

    function _vote(
        uint _tokenId, 
        uint _profileId, 
        uint _poolWeight, 
        address _user,
        address _ve, 
        bool _freeToken
    ) internal {
        string memory cid = string(abi.encodePacked(_profileId, _ve));
        if (IProfile(IContract(contractAddress).profile()).isUnique(_profileId)) {
            // if (_freeToken) _reset(_tokenId, _profileId, _ve);
            address _gauge = gauges[_profileId][_ve];
            require(isGauge[_gauge], "RV1");
            // if (_freeToken) require(votes[_tokenId][cid] == 0, "RV1");
            require(_poolWeight != 0, "RV2");
            _updateFor(_gauge, _ve);

            weights[_profileId][_ve] += _poolWeight;
            votes[_tokenId][cid] += _poolWeight;
            IReferralVoter(bribes[_gauge]).deposit(_poolWeight, _tokenId);
            emit Voted(_profileId, _tokenId, _poolWeight, _ve, _user);

            totalWeight[_ve] += _poolWeight;
            usedWeights[_tokenId][_ve] = _poolWeight;
        }
    }

    function vote(
        uint tokenId, 
        uint _referrerProfileId, 
        uint _poolWeight, 
        address _ve, 
        address _user, 
        bool _freeToken
    ) external {
        require(IContract(contractAddress).nfticketHelper() == msg.sender, "RV3");

        require(ve(_ve).isApprovedOrOwner(_user, tokenId), "RV4");
        _vote(tokenId, _referrerProfileId, _poolWeight, _user, _ve, _freeToken);
        try ve(_ve).attach(tokenId, 86400*7) {} catch{}
    }

    function createGauge(address _ve) external returns (address) {
        address profile = IContract(contractAddress).profile();
        uint _profileId = IProfile(profile).addressToProfileId(msg.sender);
        uint _collectionId = IMarketPlace(IContract(contractAddress).marketCollections()).addressToCollectionId(msg.sender);
        require(IProfile(profile).isUnique(_profileId), "RV5");
        require(gauges[_profileId][_ve] == address(0x0), "RV6");
        address _bribe = IBribe(IContract(contractAddress).referralBribeFactory()).createBribe(_ve);
        address _gauge = IGauge(IContract(contractAddress).businessGaugeFactory()).createGauge(_collectionId, _ve);
        erc20(ve(_ve).token()).approve(_gauge, type(uint).max);
        bribes[_gauge] = _bribe;
        gauges[_profileId][_ve] = _gauge;
        poolForGauge[_gauge] = _profileId;
        isGauge[_gauge] = true;
        _updateFor(_gauge, _ve);
        pools[_ve].push(_profileId);
        emit GaugeCreated(_profileId, _ve, _gauge, msg.sender, _bribe);
        return _gauge;
    }

    function emitDeposit(uint tokenId, address account, uint amount) external {
        require(isGauge[msg.sender], "RV7");
        emit Deposit(account, msg.sender, tokenId, amount);
    }

    function emitWithdraw(uint tokenId, address account, uint amount) external {
        require(isGauge[msg.sender], "RV8");
        emit Withdraw(account, msg.sender, tokenId, amount);
    }

    function length(address _ve) external view returns (uint) {
        return pools[_ve].length;
    }

    uint internal index;
    mapping(address => uint) internal supplyIndex;
    mapping(address => uint) public claimable;

    function notifyRewardAmount(address _ve, uint amount) external {
        _safeTransferFrom(ve(_ve).token(), msg.sender, address(this), amount); // transfer the distro in
        uint256 _ratio = amount * 1e18 / totalWeight[_ve]; // 1e18 adjustment is removed during claim
        if (_ratio > 0) {
            index += _ratio;
        }
        emit NotifyReward(msg.sender, _ve, amount);
    }

    function updateFor(address[] memory _gauges, address _ve) external {
        for (uint i = 0; i < _gauges.length; i++) {
            _updateFor(_gauges[i], _ve);
        }
    }

    function updateForRange(uint start, uint end, address _ve) public {
        for (uint i = start; i < end; i++) {
            _updateFor(gauges[pools[_ve][i]][_ve], _ve);
        }
    }

    function updateAll(address _ve) external {
        updateForRange(0, pools[_ve].length, _ve);
    }

    function updateGauge(address _gauge, address _ve) external {
        _updateFor(_gauge, _ve);
    }

    function _updateFor(address _gauge, address _ve) internal {
        uint _profileId = poolForGauge[_gauge];
        uint _supplied = weights[_profileId][_ve];
        if (_supplied > 0) {
            uint _supplyIndex = supplyIndex[_gauge];
            uint _index = index; // get global index0 for accumulated distro
            supplyIndex[_gauge] = _index; // update _gauge current position to global position
            uint _delta = _index - _supplyIndex; // see if there is any difference that need to be accrued
            if (_delta > 0) {
                uint _share = _supplied * _delta / 1e18; // add accrued difference for each supplied token
                claimable[_gauge] += _share;
            }
        } else {
            supplyIndex[_gauge] = index; // new users are set to the default global state
        }
    }

    function claimRewards(address[] memory _gauges, address[][] memory _tokens) external {
        for (uint i = 0; i < _gauges.length; i++) {
            IBusinessVoter(_gauges[i]).getReward(_tokens[i]);
        }
    }

    function claimBribes(address _ve, address[] memory _bribes, address[][] memory _tokens, uint _tokenId) external {
        require(ve(_ve).isApprovedOrOwner(msg.sender, _tokenId), "RV9");
        for (uint i = 0; i < _bribes.length; i++) {
            IBribe(_bribes[i]).getRewardForOwner(_tokenId, _tokens[i]);
        }
    }

    function distribute(address _gauge, address _ve) public lock {
        _updateFor(_gauge, _ve);
        uint _claimable = claimable[_gauge];
        if (_claimable > 0) {
            claimable[_gauge] = 0;
            IGauge(_gauge).notifyRewardAmount(ve(_ve).token(), _claimable);
            emit DistributeReward(msg.sender, _gauge, _claimable);
        }
    }

    function emitUpdateMiscellaneous(
        uint _idx, 
        uint _collectionId, 
        string memory paramName, 
        string memory paramValue, 
        uint paramValue2, 
        uint paramValue3,
        address paramValue4,
        string memory paramValue5
    ) external {
        emit UpdateMiscellaneous(
            _idx, 
            _collectionId, 
            paramName, 
            paramValue, 
            paramValue2, 
            paramValue3, 
            msg.sender,
            paramValue4,
            paramValue5
        );
    }

    // function distro(address _ve) external {
    //     distribute(0, pools[_ve].length, _ve);
    // }

    // function distribute(address _ve) external {
    //     distribute(0, pools[_ve].length, _ve);
    // }

    // function distribute(uint start, uint finish, address _ve) public {
    //     for (uint x = start; x < finish; x++) {
    //         distribute(gauges[pools[_ve][x]][_ve], _ve);
    //     }
    // }

    // function distribute(address[] memory _gauges, address _ve) external {
    //     for (uint x = 0; x < _gauges.length; x++) {
    //         distribute(_gauges[x], _ve);
    //     }
    // }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        require(token.code.length > 0, "RV10");
        (bool success, bytes memory data) =
        token.call(abi.encodeWithSelector(erc20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "RV11");
    }
}