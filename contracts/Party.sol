/*
__/\\\\\\\\\\\\\_____________________________________________________________/\\\\\\\\\\\\________/\\\\\\\\\__________/\\\\\______
 _\/\\\/////////\\\__________________________________________________________\/\\\////////\\\____/\\\\\\\\\\\\\______/\\\///\\\____
  _\/\\\_______\/\\\__________________________________/\\\_________/\\\__/\\\_\/\\\______\//\\\__/\\\/////////\\\___/\\\/__\///\\\__
   _\/\\\\\\\\\\\\\/___/\\\\\\\\\_____/\\/\\\\\\\___/\\\\\\\\\\\___\//\\\/\\\__\/\\\_______\/\\\_\/\\\_______\/\\\__/\\\______\//\\\_
    _\/\\\/////////____\////////\\\___\/\\\/////\\\_\////\\\////_____\//\\\\\___\/\\\_______\/\\\_\/\\\\\\\\\\\\\\\_\/\\\_______\/\\\_
     _\/\\\_______________/\\\\\\\\\\__\/\\\___\///_____\/\\\__________\//\\\____\/\\\_______\/\\\_\/\\\/////////\\\_\//\\\______/\\\__
      _\/\\\______________/\\\/////\\\__\/\\\____________\/\\\_/\\___/\\_/\\\_____\/\\\_______/\\\__\/\\\_______\/\\\__\///\\\__/\\\____
       _\/\\\_____________\//\\\\\\\\/\\_\/\\\____________\//\\\\\___\//\\\\/______\/\\\\\\\\\\\\/___\/\\\_______\/\\\____\///\\\\\/_____
        _\///_______________\////////\//__\///______________\/////_____\////________\////////////_____\///________\///_______\/////_______

Anna Carroll for PartyDAO
*/

// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

// ============ External Imports: Inherited Contracts ============
// NOTE: we inherit from OpenZeppelin upgradeable contracts
// because of the proxy structure used for cheaper deploys
// (the proxies are NOT actually upgradeable)
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {ERC721HolderUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
// ============ External Imports: External Contracts & Contract Interfaces ============
import {IWETH} from "./external/interfaces/IWETH.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// ============ Internal Imports ============
import {Structs} from "./Structs.sol";

contract Party is ReentrancyGuardUpgradeable, ERC721HolderUpgradeable {
    // ============ Enums ============

    // State Transitions:
    //   (0) ACTIVE on deploy
    //   (1) WON if the Party has won the token
    //   (2) LOST if the Party is over & did not win the token
    enum PartyStatus {
        ACTIVE,
        WON,
        LOST
    }

    // ============ Structs ============

    struct Contribution {
        uint256 amount;
        uint256 previousTotalContributedToParty;
    }

    // ============ Internal Constants ============

    // PartyDAO receives an ETH fee equal to 2.5% of the amount spent
    uint16 internal constant ETH_FEE_BASIS_POINTS = 250;

    // ============ Immutables ============

    address public immutable partyFactory;
    address public immutable partyDAOMultisig;
    IWETH public immutable weth;

    // ============ Public Not-Mutated Storage ============

    // NFT contract
    IERC721Metadata public nftContract;
    // ID of token within NFT contract
    uint256 public tokenId;
    // address of token that users need to hold to contribute
    // address(0) if party is not token gated
    IERC20 public gatedToken;
    // amount of token that users need to hold to contribute
    // 0 if party is not token gated
    uint256 public gatedTokenAmount;

    // ============ Public Mutable Storage ============

    // state of the contract
    PartyStatus public partyStatus;
    // total ETH deposited by all contributors
    uint256 public totalContributedToParty;
    // the total spent buying the token;
    // 0 if the NFT is not won; price of token + 2.5% PartyDAO fee if NFT is won
    uint256 public totalSpent;
    // contributor => array of Contributions
    mapping(address => Contribution[]) public contributions;
    // contributor => total amount contributed
    mapping(address => uint256) public totalContributed;
    // contributor => true if contribution has been claimed
    mapping(address => bool) public claimed;
    // post-auction manager contract
    address public handler;

    // ============ Events ============

    event Contributed(
        address indexed contributor,
        uint256 amount,
        uint256 previousTotalContributedToParty,
        uint256 totalFromContributor
    );

    event Claimed(
        address indexed contributor,
        uint256 totalContributed,
        uint256 excessContribution
    );

    // ======== Modifiers =========

    modifier onlyPartyDAO() {
        require(
            msg.sender == partyDAOMultisig,
            "Party:: only PartyDAO multisig"
        );
        _;
    }

    modifier onlyHandler() {
        require(
            msg.sender == handler,
            "Party:: only Handler"
        );
        _;
    }

    // ======== Constructor =========

    constructor(
        address _partyDAOMultisig,
        address _weth
    ) {
        partyFactory = msg.sender;
        partyDAOMultisig = _partyDAOMultisig;
        weth = IWETH(_weth);
    }

    // ======== Internal: Initialize =========

    function __Party_init(
        address _nftContract,
        Structs.AddressAndAmount calldata _tokenGate
    ) internal {
        require(
            msg.sender == partyFactory,
            "Party::__Party_init: only factory can init"
        );
        // if token gating is non-zero
        if (_tokenGate.addr != address(0) && _tokenGate.amount != 0) {
            // call totalSupply to verify that address is ERC-20 token contract
            IERC20(_tokenGate.addr).totalSupply();
            gatedToken = IERC20(_tokenGate.addr);
            gatedTokenAmount = _tokenGate.amount;
        }
        // initialize ReentrancyGuard and ERC721Holder
        __ReentrancyGuard_init();
        __ERC721Holder_init();
        // set storage variables
        nftContract = IERC721Metadata(_nftContract);
    }

    // ======== Internal: Contribute =========

    /**
     * @notice Contribute to the Party's treasury
     * while the Party is still active
     * @dev Emits a Contributed event upon success; callable by anyone
     */
    function _contribute() internal {
        require(
            partyStatus == PartyStatus.ACTIVE,
            "Party::contribute: party not active"
        );
        address _contributor = msg.sender;
        uint256 _amount = msg.value;
        // if token gated, require that contributor has balance of gated tokens
        if (address(gatedToken) != address(0)) {
            require(
                gatedToken.balanceOf(_contributor) >= gatedTokenAmount,
                "Party::contribute: must hold tokens to contribute"
            );
        }
        require(_amount > 0, "Party::contribute: must contribute more than 0");
        // get the current contract balance
        uint256 _previousTotalContributedToParty = totalContributedToParty;
        // add contribution to contributor's array of contributions
        Contribution memory _contribution = Contribution({
            amount: _amount,
            previousTotalContributedToParty: _previousTotalContributedToParty
        });
        contributions[_contributor].push(_contribution);
        // add to contributor's total contribution
        totalContributed[_contributor] =
            totalContributed[_contributor] +
            _amount;
        // add to party's total contribution & emit event
        totalContributedToParty = _previousTotalContributedToParty + _amount;
        emit Contributed(
            _contributor,
            _amount,
            _previousTotalContributedToParty,
            totalContributed[_contributor]
        );
    }

    // ======== External: Claim =========

    /**
     * @notice Claim the tokens and excess ETH owed
     * to a single contributor after the party has ended
     * @dev Emits a Claimed event upon success
     * callable by anyone (doesn't have to be the contributor)
     * @param _contributor the address of the contributor
     */
    function claim(address _contributor) external nonReentrant {
        // ensure party has finalized
        require(
            partyStatus != PartyStatus.ACTIVE,
            "Party::claim: party not finalized"
        );
        // ensure contributor submitted some ETH
        require(
            totalContributed[_contributor] != 0,
            "Party::claim: not a contributor"
        );
        // ensure the contributor hasn't already claimed
        require(
            !claimed[_contributor],
            "Party::claim: contribution already claimed"
        );
        // mark the contribution as claimed
        claimed[_contributor] = true;
        // calculate the amount of excess ETH owed to the user
        (, uint256 _ethAmount) = getClaimAmounts(
            _contributor
        );
        // if there is excess ETH, send it back to the contributor
        _transferETHOrWETH(_contributor, _ethAmount);
        emit Claimed(
            _contributor,
            totalContributed[_contributor],
            _ethAmount
        );
    }

    // ======== External: Handler actions (Handler Only) ========

    /**
     * @notice Transfer the NFT
     * The caller is responsible to confirm that `_to` is
     * capable of receiving the NFT, otherwise the NFT may be
     * permanently lost.
     */
    function moveNft(address _to) external onlyHandler {
        nftContract.transferFrom(address(this), _to, tokenId);
    }

    // ======== External: Setting the handler (PartyDAO Multisig Only) ========

    /**
     * @notice Set the handler contract for the party
     * PartyDAO can set the handler for the post-auction experience
     */
    function setHandler(address _handler) external onlyPartyDAO {
        handler = _handler;
    }

    // ======== External: Emergency Escape Hatches (PartyDAO Multisig Only) =========

    /**
     * @notice Escape hatch: in case of emergency,
     * PartyDAO can use emergencyWithdrawEth to withdraw
     * ETH stuck in the contract
     */
    function emergencyWithdrawEth(uint256 _value) external onlyPartyDAO {
        _transferETHOrWETH(partyDAOMultisig, _value);
    }

    /**
     * @notice Escape hatch: in case of emergency,
     * PartyDAO can use emergencyCall to call an external contract
     * (e.g. to withdraw a stuck NFT or stuck ERC-20s)
     */
    function emergencyCall(address _contract, bytes memory _calldata)
        external
        onlyPartyDAO
        returns (bool _success, bytes memory _returnData)
    {
        (_success, _returnData) = _contract.call(_calldata);
        require(_success, string(_returnData));
    }

    /**
     * @notice Escape hatch: in case of emergency,
     * PartyDAO can force the Party to finalize with status LOST
     * (e.g. if finalize is not callable)
     */
    function emergencyForceLost() external onlyPartyDAO {
        // set partyStatus to LOST
        partyStatus = PartyStatus.LOST;
    }

    // ======== Public: Utility Calculations =========

    /**
     * @notice The maximum amount that can be spent by the Party
     * while paying the ETH fee to PartyDAO
     * @return _maxSpend the maximum spend
     */
    function getMaximumSpend() public view returns (uint256 _maxSpend) {
        _maxSpend =
            (totalContributedToParty * 10000) /
            (10000 + ETH_FEE_BASIS_POINTS);
    }

    /**
     * @notice Calculate the amount of ETH used (ownership of the contributor)
     * based on how much ETH they contributed towards buying the token,
     * and the amount of excess ETH owed to the contributor
     * based on how much ETH they contributed *not* used towards buying the token
     * @param _contributor the address of the contributor
     * @return _ethUsedOnPurchase the amount of ETH used from the contributor
     * @return _ethAmount the amount of excess ETH owed to the contributor
     */
    function getClaimAmounts(address _contributor)
        public
        view
        returns (uint256 _ethUsedOnPurchase, uint256 _ethAmount)
    {
        require(
            partyStatus != PartyStatus.ACTIVE,
            "Party::getClaimAmounts: party still active; amounts undetermined"
        );
        uint256 _totalContributed = totalContributed[_contributor];
        if (partyStatus == PartyStatus.WON) {
            // calculate the amount of this contributor's ETH
            // that was used to buy the token
            _ethUsedOnPurchase = totalEthUsed(_contributor);
            // the rest of the contributor's ETH should be returned
            _ethAmount = _totalContributed - _ethUsedOnPurchase;
        } else {
            // if the token wasn't bought, no ETH was spent;
            // all of the contributor's ETH should be returned
            _ethAmount = _totalContributed;
        }
    }

    /**
     * @notice Calculate the total amount of a contributor's funds
     * that were used towards the buying the token
     * @dev always returns 0 until the party has been finalized
     * @param _contributor the address of the contributor
     * @return _total the sum of the contributor's funds that were
     * used towards buying the token
     */
    function totalEthUsed(address _contributor)
        public
        view
        returns (uint256 _total)
    {
        require(
            partyStatus != PartyStatus.ACTIVE,
            "Party::totalEthUsed: party still active; amounts undetermined"
        );
        // load total amount spent once from storage
        uint256 _totalSpent = totalSpent;
        // get all of the contributor's contributions
        Contribution[] memory _contributions = contributions[_contributor];
        for (uint256 i = 0; i < _contributions.length; i++) {
            // calculate how much was used from this individual contribution
            uint256 _amount = _ethUsed(_totalSpent, _contributions[i]);
            // if we reach a contribution that was not used,
            // no subsequent contributions will have been used either,
            // so we can stop calculating to save some gas
            if (_amount == 0) break;
            _total = _total + _amount;
        }
    }

    // ============ Internal ============

    function _closeSuccessfulParty(uint256 _nftCost)
        internal
        returns (uint256 _ethFee)
    {
        // calculate PartyDAO fee & record total spent
        _ethFee = _getEthFee(_nftCost);
        totalSpent = _nftCost + _ethFee;
        // transfer ETH fee to PartyDAO
        _transferETHOrWETH(partyDAOMultisig, _ethFee);
        // TODO: maybe store the NFT cost in the contract?
    }

    /**
     * @notice Calculate ETH fee for PartyDAO
     * NOTE: Remove this fee causes a critical vulnerability
     * allowing anyone to exploit a Party via price manipulation.
     * See Security Review in README for more info.
     * @return _fee the portion of _amount represented by scaling to ETH_FEE_BASIS_POINTS
     */
    function _getEthFee(uint256 _amount) internal pure returns (uint256 _fee) {
        _fee = (_amount * ETH_FEE_BASIS_POINTS) / 10000;
    }

    /**
     * @notice Query the NFT contract to get the token owner
     * @dev nftContract must implement the ERC-721 token standard exactly:
     * function ownerOf(uint256 _tokenId) external view returns (address);
     * See https://eips.ethereum.org/EIPS/eip-721
     * @dev Returns address(0) if NFT token or NFT contract
     * no longer exists (token burned or contract self-destructed)
     * @return _owner the owner of the NFT
     */
    function _getOwner() internal view returns (address _owner) {
        (bool _success, bytes memory _returnData) = address(nftContract)
            .staticcall(abi.encodeWithSignature("ownerOf(uint256)", tokenId));
        if (_success && _returnData.length > 0) {
            _owner = abi.decode(_returnData, (address));
        }
    }

    // ============ Internal: Claim ============

    /**
     * @notice Calculate the amount of a single Contribution
     * that was used towards buying the token
     * @param _contribution the Contribution struct
     * @return the amount of funds from this contribution
     * that were used towards buying the token
     */
    function _ethUsed(uint256 _totalSpent, Contribution memory _contribution)
        internal
        pure
        returns (uint256)
    {
        if (
            _contribution.previousTotalContributedToParty +
                _contribution.amount <=
            _totalSpent
        ) {
            // contribution was fully used
            return _contribution.amount;
        } else if (
            _contribution.previousTotalContributedToParty < _totalSpent
        ) {
            // contribution was partially used
            return _totalSpent - _contribution.previousTotalContributedToParty;
        }
        // contribution was not used
        return 0;
    }

    // ============ Internal: TransferEthOrWeth ============

    /**
     * @notice Attempt to transfer ETH to a recipient;
     * if transferring ETH fails, transfer WETH insteads
     * @param _to recipient of ETH or WETH
     * @param _value amount of ETH or WETH
     */
    function _transferETHOrWETH(address _to, uint256 _value) internal {
        // skip if attempting to send 0 ETH
        if (_value == 0) {
            return;
        }
        // guard against rounding errors;
        // if ETH amount to send is greater than contract balance,
        // send full contract balance
        if (_value > address(this).balance) {
            _value = address(this).balance;
        }
        // Try to transfer ETH to the given recipient.
        if (!_attemptETHTransfer(_to, _value)) {
            // If the transfer fails, wrap and send as WETH
            weth.deposit{value: _value}();
            weth.transfer(_to, _value);
            // At this point, the recipient can unwrap WETH.
        }
    }

    /**
     * @notice Attempt to transfer ETH to a recipient
     * @dev Sending ETH is not guaranteed to succeed
     * this method will return false if it fails.
     * We will limit the gas used in transfers, and handle failure cases.
     * @param _to recipient of ETH
     * @param _value amount of ETH
     */
    function _attemptETHTransfer(address _to, uint256 _value)
        internal
        returns (bool)
    {
        // Here increase the gas limit a reasonable amount above the default, and try
        // to send ETH to the recipient.
        // NOTE: This might allow the recipient to attempt a limited reentrancy attack.
        (bool success, ) = _to.call{value: _value, gas: 30000}("");
        return success;
    }
}
