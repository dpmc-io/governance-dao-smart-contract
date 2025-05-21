// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IERC20 {
    function tokenLocked(address account) external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function totalSupply() external view returns (uint256);
}

contract GovernanceDAO is ReentrancyGuard {
    enum Tier {
        NoTier,
        Bronze,
        Silver,
        Gold,
        VIP
    }

    enum VoteMethod {
        TierPoint,
        HoldingPercentage,
        CappedHoldingPercentage
    }

    enum Status {
        Draft,
        Chosen,
        Passed,
        Rejected,
        Done,
        Cancelled
    }

    struct Proposal {
        uint256 id;
        string title;
        string description;
        string[] choices;
        address creator;
        Status status;
        uint256 startTime;
        uint256 endTime;
        uint256 sessionId; // Session ID for the proposal
    }

    struct VoteDetail {
        uint256 proposalId;
        uint256 choiceIndex;
        address voter;
        uint256 weight;
        VoteMethod method;
    }

    uint256 public MIN_VIP_THRESHOLD = 2_000_000 * 10 ** 18;
    uint256 public MIN_GOLD_THRESHOLD = 1_000_000 * 10 ** 18;
    uint256 public MIN_SILVER_THRESHOLD = 500_000 * 10 ** 18;
    uint256 public MIN_BRONZE_THRESHOLD = 100_000 * 10 ** 18;
    uint256 public MIN_NOTIER_THRESHOLD = 0;

    IERC20 public tokenLock;
    address public admin;
    uint256 public proposalCounter;
    uint256 public constant PERCENTAGE_BASE = 1_000_000; // 100% = 1,000,000
    uint256 public MAX_CAPPED_PERCENTAGE = 30_000; // 3%
    uint256 public votingDuration = 7 days;
    VoteMethod public voteMethod = VoteMethod.TierPoint;
    bool public daoPaused;
    uint256 public activeProposalId;

    uint256 public sessionCounter = 1; // Tracks voting sessions
    mapping(uint256 => mapping(uint256 => uint256))
        public draftProposalsBySession; // sessionId => index => proposalId
    mapping(uint256 => uint256) public draftProposalsCountBySession; // sessionId => count of draft proposals
    mapping(uint256 => uint256) public proposalToSession; // proposalId => sessionId
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => VoteDetail))
        public proposalVoteDetails; // proposalId => voter => VoteDetail
    mapping(uint256 => mapping(uint256 => uint256)) public finalizedVotes; // proposalId => choiceIndex => weight
    mapping(uint256 => address[]) public proposalVoters; // proposalId => list of voters
    mapping(uint256 => mapping(address => bool))
        public hasCreatedProposalInSession;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    modifier whenNotPaused() {
        require(!daoPaused, "DAO is paused");
        _;
    }

    event ProposalCreated(
        uint256 proposalId,
        string title,
        string description,
        string[] choices
    );
    event Voted(
        uint256 proposalId,
        address voter,
        uint256 choiceIndex,
        uint256 weight,
        VoteMethod method
    );
    event ProposalCancelled(uint256 proposalId);
    event ProposalStatusUpdated(uint256 proposalId, Status newStatus);
    event DAOStatusUpdated(bool paused);
    event SessionClosed(
        uint256 sessionId,
        uint256 chosenProposalId,
        string message
    );

    constructor(address _lockingToken) {
        admin = msg.sender;
        tokenLock = IERC20(_lockingToken);
    }

    function updateTierThresholds(
        uint256 _vip,
        uint256 _gold,
        uint256 _silver,
        uint256 _bronze
    ) external onlyAdmin {
        require(_vip > _gold, "VIP threshold must be greater than Gold");
        require(_gold > _silver, "Gold threshold must be greater than Silver");
        require(
            _silver > _bronze,
            "Silver threshold must be greater than Bronze"
        );
        require(_bronze > 0, "Bronze threshold must be greater than 0");

        MIN_VIP_THRESHOLD = _vip;
        MIN_GOLD_THRESHOLD = _gold;
        MIN_SILVER_THRESHOLD = _silver;
        MIN_BRONZE_THRESHOLD = _bronze;
        MIN_NOTIER_THRESHOLD = 0;
    }

    function getTier(address account) public view returns (Tier tier) {
        uint256 availableBalance = tokenLock.balanceOf(account);
        uint256 totalLocked = tokenLock.tokenLocked(account);
        uint256 totalAmount = availableBalance + totalLocked;

        if (totalAmount >= MIN_VIP_THRESHOLD) {
            return Tier.VIP;
        } else if (totalAmount >= MIN_GOLD_THRESHOLD) {
            return Tier.Gold;
        } else if (totalAmount >= MIN_SILVER_THRESHOLD) {
            return Tier.Silver;
        } else if (totalAmount >= MIN_BRONZE_THRESHOLD) {
            return Tier.Bronze;
        } else if (totalAmount < MIN_BRONZE_THRESHOLD) {
            return Tier.NoTier;
        }
    }

    function setMaxPercentage(uint256 _percent) external onlyAdmin {
        require(_percent <= 100, "Cannot exceed 100%");
        MAX_CAPPED_PERCENTAGE = _percent;
    }

    function getTotalSupply() public view returns (uint256) {
        return tokenLock.totalSupply();
    }

    function calculateVotePercentage(
        address account
    ) public view returns (uint256) {
        uint256 availableBalance = tokenLock.balanceOf(account);
        uint256 totalLocked = tokenLock.tokenLocked(account);
        uint256 totalAmount = availableBalance + totalLocked;
        if (getTotalSupply() == 0) return 0;
        return (totalAmount * PERCENTAGE_BASE) / getTotalSupply();
    }

    function cappedPercentage(address account) public view returns (uint256) {
        uint256 rawPercent = calculateVotePercentage(account);
        return
            rawPercent > MAX_CAPPED_PERCENTAGE
                ? MAX_CAPPED_PERCENTAGE
                : rawPercent;
    }

    function createProposal(
        string memory _title,
        string memory _description,
        string[] memory _choices
    ) external onlyAdmin whenNotPaused {
        require(
            _choices.length >= 2 && _choices.length <= 4,
            "Invalid choice count"
        );
        require(
            activeProposalId == 0 ||
                block.timestamp > proposals[activeProposalId].endTime,
            "There is already an active proposal"
        );

        proposalCounter++;
        uint256 currentSessionId = sessionCounter;

        require(
            !hasCreatedProposalInSession[currentSessionId][msg.sender],
            "You have already created a proposal in this session"
        );

        proposals[proposalCounter] = Proposal({
            id: proposalCounter,
            title: _title,
            description: _description,
            choices: _choices,
            creator: msg.sender,
            status: Status.Draft,
            startTime: 0,
            endTime: 0,
            sessionId: currentSessionId
        });

        // Store the proposal in the session
        uint256 proposalIndex = draftProposalsCountBySession[currentSessionId];
        draftProposalsBySession[currentSessionId][
            proposalIndex
        ] = proposalCounter;
        draftProposalsCountBySession[currentSessionId]++;

        proposalToSession[proposalCounter] = currentSessionId;

        // Mark the sender as having created a proposal in this session
        hasCreatedProposalInSession[currentSessionId][msg.sender] = true;

        emit ProposalCreated(proposalCounter, _title, _description, _choices);
    }

    function selectProposal(
        uint256 _proposalId,
        string memory _newTitle,
        string memory _newDescription,
        string[] memory _newChoices
    ) external onlyAdmin {
        require(
            proposals[_proposalId].status == Status.Draft,
            "Only draft proposals can be selected"
        );
        require(
            _newChoices.length >= 2 && _newChoices.length <= 4,
            "Invalid choice count"
        );

        Proposal storage proposal = proposals[_proposalId];
        uint256 sessionId = proposal.sessionId;
        uint256 draftCount = draftProposalsCountBySession[sessionId];

        for (uint256 i = 0; i < draftCount; i++) {
            uint256 proposalIdInSession = draftProposalsBySession[sessionId][i];
            if (
                proposalIdInSession != _proposalId &&
                proposals[proposalIdInSession].status == Status.Draft
            ) {
                proposals[proposalIdInSession].status = Status.Rejected;
            }
        }

        // Update selected proposal
        proposal.title = _newTitle;
        proposal.description = _newDescription;
        proposal.choices = _newChoices;
        proposal.status = Status.Chosen;
        proposal.startTime = block.timestamp;
        proposal.endTime = block.timestamp + votingDuration;

        activeProposalId = _proposalId;
        sessionCounter++;

        emit SessionClosed(
            sessionId,
            _proposalId,
            "Session closed, chosen proposal selected and unchosen proposals rejected"
        );

        emit ProposalCreated(
            proposalCounter,
            _newTitle,
            _newDescription,
            _newChoices
        );
    }

    function getTierWeight(address voter) internal view returns (uint256) {
        Tier tier = getTier(voter);
        if (tier == Tier.VIP) {
            return 4;
        } else if (tier == Tier.Gold) {
            return 3;
        } else if (tier == Tier.Silver) {
            return 2;
        } else if (tier == Tier.Bronze) {
            return 1;
        }
        return 0;
    }

    function vote(
        uint256 _proposalId,
        uint256 _choiceIndex
    ) external whenNotPaused nonReentrant {
        Proposal storage proposal = proposals[_proposalId];
        require(block.timestamp <= proposal.endTime, "Voting ended");
        require(proposal.status == Status.Chosen, "Not active");
        require(_choiceIndex < proposal.choices.length, "Invalid choice");

        // Ensure the voter hasn't already voted on this proposal
        require(
            proposalVoteDetails[_proposalId][msg.sender].voter == address(0),
            "Already voted"
        );

        uint256 calculatedWeight;

        if (voteMethod == VoteMethod.TierPoint) {
            // If voting method is TierPoint, calculate weight based on user tier
            uint256 tierWeight = getTierWeight(msg.sender);
            calculatedWeight = tierWeight;
        } else if (voteMethod == VoteMethod.HoldingPercentage) {
            // If voting method is HoldingPercentage, calculate weight based on token holding percentage
            uint256 tokenHoldingPercentage = calculateVotePercentage(
                msg.sender
            );
            calculatedWeight = tokenHoldingPercentage;
        } else if (voteMethod == VoteMethod.CappedHoldingPercentage) {
            // If voting method is CappedHoldingPercentage, calculate weight with max cap
            uint256 tokenHoldingPercentage = cappedPercentage(msg.sender);
            uint256 cappedWeight = tokenHoldingPercentage >
                MAX_CAPPED_PERCENTAGE
                ? MAX_CAPPED_PERCENTAGE
                : tokenHoldingPercentage;
            calculatedWeight = cappedWeight;
        }

        // Update the votes for the specific choice
        finalizedVotes[_proposalId][_choiceIndex] += calculatedWeight;

        // Store the vote details for the voter
        proposalVoteDetails[_proposalId][msg.sender] = VoteDetail({
            proposalId: _proposalId,
            choiceIndex: _choiceIndex,
            voter: msg.sender,
            weight: calculatedWeight,
            method: voteMethod
        });

        emit Voted(
            _proposalId,
            msg.sender,
            _choiceIndex,
            calculatedWeight,
            voteMethod
        );
    }

    function cancelProposal(uint256 _proposalId) external onlyAdmin {
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.status == Status.Chosen, "Not active");
        proposal.status = Status.Cancelled;

        if (activeProposalId == _proposalId) {
            activeProposalId = 0;
        }

        emit ProposalCancelled(_proposalId);
    }

    function updateProposalStatus(
        uint256 _proposalId,
        Status _status
    ) external onlyAdmin {
        Proposal storage proposal = proposals[_proposalId];
        require(
            _status == Status.Passed ||
                _status == Status.Rejected ||
                _status == Status.Done,
            "Invalid status update"
        );
        proposal.status = _status;

        if (activeProposalId == _proposalId) {
            activeProposalId = 0;
        }

        emit ProposalStatusUpdated(_proposalId, _status);
    }

    function updateVotingDuration(uint256 _days) external onlyAdmin {
        require(_days >= 1 days, "Voting duration too short");
        votingDuration = _days * 1 days;
    }

    function setVoteMethod(VoteMethod _method) external onlyAdmin {
        require(
            block.timestamp > proposals[activeProposalId].endTime,
            "Cannot change vote method while an active proposal is ongoing"
        );
        voteMethod = _method;
    }

    function pauseDAO(bool _pause) external onlyAdmin {
        daoPaused = _pause;
        emit DAOStatusUpdated(_pause);
    }

    function getProposalVote(
        uint256 _proposalId,
        uint256 _choiceIndex
    ) external view returns (uint256) {
        return finalizedVotes[_proposalId][_choiceIndex];
    }

    function getFinalizedVotes(
        uint256 _proposalId
    ) external view returns (uint256[] memory) {
        uint256 choiceCount = proposals[_proposalId].choices.length;
        uint256[] memory votes = new uint256[](choiceCount);

        for (uint256 i = 0; i < choiceCount; i++) {
            votes[i] = finalizedVotes[_proposalId][i];
        }

        return votes;
    }

    function getWinningChoice(
        uint256 _proposalId
    )
        external
        view
        returns (uint256 winningChoiceIndex, uint256 winningWeight)
    {
        Proposal storage proposal = proposals[_proposalId];
        uint256 choiceCount = proposal.choices.length;

        uint256 highestVote = 0;
        uint256 winningChoice = 0;

        for (uint256 i = 0; i < choiceCount; i++) {
            uint256 currentChoiceVote = finalizedVotes[_proposalId][i];
            if (currentChoiceVote > highestVote) {
                highestVote = currentChoiceVote;
                winningChoice = i;
            }
        }

        return (winningChoice, highestVote);
    }

    function getActiveProposal() external view returns (Proposal memory) {
        require(activeProposalId != 0, "No active proposal");
        return proposals[activeProposalId];
    }
}
