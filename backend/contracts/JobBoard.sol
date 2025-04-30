// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// Import ReentrancyGuard for security and Ownable for admin control
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title JobBoard
 * @dev Handles job postings, applications (via events), assignment, escrow,
 * work submission, payment, refunds, disputes, deletion, and withdrawal.
 * Descriptions and Application Details stored off-chain (IPFS CIDs).
 */
contract JobBoard is ReentrancyGuard, Ownable {

    // Enum defining the possible states of a job
    enum JobStatus { OPEN, ASSIGNED, AWAITING_APPROVAL, COMPLETED, REFUNDED, DISPUTED, DELETED }

    // Struct representing a job posting
    struct Job {
        uint256 id;
        string title;
        string descriptionCID;  // IPFS CID for the job description
        uint256 budget;
        address payable employer;
        // Freelancer is set only when assigned by employer
        address payable freelancer;
        JobStatus status;
        uint256 escrowTime;     // Timestamp when funds were escrowed
    }

    uint256 public jobCount; // Counter for total jobs posted
    mapping(uint256 => Job) public jobs; // Mapping from job ID to Job struct
    mapping(uint256 => uint256) public escrowedFunds; // Mapping from job ID to escrowed amount

    // Refund delay set to 1 minute as requested
    uint256 public constant REFUND_DELAY = 1 minutes;

    // --- Events ---
    event JobPosted(uint256 indexed jobId, address indexed employer, string title, uint256 budget, string descriptionCID);
    event JobAssigned(uint256 indexed jobId, address indexed freelancer); // Renamed from JobApplied
    event ApplicationSubmitted(uint256 indexed jobId, address indexed applicant, string applicationCID); // For tracking applications
    event PaymentEscrowed(uint256 indexed jobId, address indexed employer, uint256 amount);
    event PaymentReleased(uint256 indexed jobId, address indexed freelancer, uint256 amount);
    event EmployerRefunded(uint256 indexed jobId, address indexed employer, uint256 amount);
    event DisputeRaised(uint256 indexed jobId, address indexed initiator);
    event DisputeResolved(uint256 indexed jobId, address indexed admin, address indexed winner, uint256 amount);
    event WorkSubmitted(uint256 indexed jobId, address indexed freelancer);
    event JobDeleted(uint256 indexed jobId); // For deleting jobs
    event ApplicationWithdrawn(uint256 indexed jobId, address indexed freelancer); // For withdrawing from assigned job


    // --- Modifiers ---
    modifier onlyEmployer(uint256 _jobId) {
        require(msg.sender == jobs[_jobId].employer, "JobBoard: Caller is not the employer");
        _;
    }

    modifier onlyFreelancer(uint256 _jobId) {
        require(msg.sender == jobs[_jobId].freelancer, "JobBoard: Caller is not the assigned freelancer");
        _;
    }

    // Modifier to check if job exists and is not deleted
    modifier jobExistsAndActive(uint256 _jobId) {
        require(_jobId > 0 && _jobId <= jobCount, "JobBoard: Job does not exist");
        require(jobs[_jobId].status != JobStatus.DELETED, "JobBoard: Job has been deleted");
        _;
    }

    constructor() Ownable(msg.sender) {}

    // --- Core Functions ---

    /**
     * @notice Allows anyone to post a new job.
     */
    function postJob(
        string memory _title,
        string memory _descriptionCID,
        uint256 _budget
    ) public {
        require(bytes(_title).length > 0, "JobBoard: Title cannot be empty");
        require(bytes(_descriptionCID).length > 0, "JobBoard: Description CID cannot be empty");
        require(_budget > 0, "JobBoard: Budget must be greater than 0");

        jobCount++;
        uint256 currentJobId = jobCount;

        jobs[currentJobId] = Job({
            id: currentJobId, title: _title, descriptionCID: _descriptionCID,
            budget: _budget, employer: payable(msg.sender), freelancer: payable(address(0)),
            status: JobStatus.OPEN, escrowTime: 0
        });

        emit JobPosted(currentJobId, msg.sender, _title, _budget, _descriptionCID);
    }

    /**
     * @notice Allows the employer to escrow the payment for an open job.
     */
    function escrowFunds(uint256 _jobId) public payable jobExistsAndActive(_jobId) onlyEmployer(_jobId) {
        Job storage job = jobs[_jobId];
        require(job.status == JobStatus.OPEN, "JobBoard: Job must be open");
        require(msg.value == job.budget, "JobBoard: Sent ETH must match job budget");
        require(escrowedFunds[_jobId] == 0, "JobBoard: Funds already escrowed");

        escrowedFunds[_jobId] = msg.value;
        job.escrowTime = block.timestamp;
        emit PaymentEscrowed(_jobId, msg.sender, msg.value);
    }

     /**
     * @notice Allows any potential freelancer to submit their application details (via IPFS CID).
     */
    function submitApplication(uint256 _jobId, string memory _applicationCID) public jobExistsAndActive(_jobId) {
        Job storage job = jobs[_jobId];
        require(job.status == JobStatus.OPEN, "JobBoard: Job not open for applications");
        require(escrowedFunds[_jobId] == job.budget, "JobBoard: Funds not escrowed");
        require(msg.sender != job.employer, "JobBoard: Employer cannot apply");
        require(bytes(_applicationCID).length > 0, "JobBoard: Application CID required");

        emit ApplicationSubmitted(_jobId, msg.sender, _applicationCID);
    }

    /**
     * @notice Allows the employer to assign a freelancer to an open, escrowed job.
     */
    function assignJob(uint256 _jobId, address payable _freelancer) public jobExistsAndActive(_jobId) onlyEmployer(_jobId) {
        Job storage job = jobs[_jobId];
        require(job.status == JobStatus.OPEN, "JobBoard: Job must be OPEN");
        require(job.freelancer == address(0), "JobBoard: Job already assigned");
        require(escrowedFunds[_jobId] == job.budget, "JobBoard: Funds must be escrowed");
        require(_freelancer != address(0), "JobBoard: Invalid freelancer address");
        require(_freelancer != job.employer, "JobBoard: Cannot assign employer");

        job.freelancer = _freelancer;
        job.status = JobStatus.ASSIGNED;
        emit JobAssigned(_jobId, _freelancer);
    }

   /**
    * @notice Allows the assigned freelancer to mark work as completed (ready for approval).
    */
    function markWorkDone(uint256 _jobId) public jobExistsAndActive(_jobId) onlyFreelancer(_jobId) nonReentrant {
        Job storage job = jobs[_jobId];
        require(job.status == JobStatus.ASSIGNED, "JobBoard: Job must be ASSIGNED");
        job.status = JobStatus.AWAITING_APPROVAL;
        emit WorkSubmitted(_jobId, msg.sender);
    }

    /**
     * @notice Allows the employer to release escrowed payment after work submission.
     */
    function releasePayment(uint256 _jobId) public jobExistsAndActive(_jobId) onlyEmployer(_jobId) nonReentrant {
        Job storage job = jobs[_jobId];
        uint256 amount = escrowedFunds[_jobId];
        require(job.status == JobStatus.AWAITING_APPROVAL, "JobBoard: Job not awaiting approval");
        require(job.freelancer != address(0), "JobBoard: No freelancer assigned");
        require(amount == job.budget && amount > 0, "JobBoard: Escrow issue");

        job.status = JobStatus.COMPLETED;
        escrowedFunds[_jobId] = 0;
        (bool success, ) = job.freelancer.call{value: amount}("");
        require(success, "JobBoard: Payment transfer failed");
        emit PaymentReleased(_jobId, job.freelancer, amount);
    }

    /**
     * @notice Allows the employer to get a refund for an OPEN job after a delay.
     */
    function refundEmployer(uint256 _jobId) public jobExistsAndActive(_jobId) onlyEmployer(_jobId) nonReentrant {
        Job storage job = jobs[_jobId];
        uint256 amount = escrowedFunds[_jobId];
        require(job.status == JobStatus.OPEN, "JobBoard: Job must be OPEN");
        require(amount > 0, "JobBoard: No funds escrowed");
        require(job.escrowTime > 0, "JobBoard: Funds never escrowed");
        require(block.timestamp >= job.escrowTime + REFUND_DELAY, "JobBoard: Refund delay not passed"); // Uses 1 min delay

        job.status = JobStatus.REFUNDED;
        escrowedFunds[_jobId] = 0;
        (bool success, ) = job.employer.call{value: amount}("");
        require(success, "JobBoard: Refund transfer failed");
        emit EmployerRefunded(_jobId, job.employer, amount);
    }

    /**
     * @notice Allows the employer to delete an OPEN job, refunding escrow if present.
     */
    function deleteJob(uint256 _jobId) public onlyEmployer(_jobId) nonReentrant {
        // Check existence manually to handle status check correctly
        require(_jobId > 0 && _jobId <= jobCount, "JobBoard: Job does not exist");
        Job storage job = jobs[_jobId];
        uint256 amount = escrowedFunds[_jobId];

        require(job.status == JobStatus.OPEN, "JobBoard: Can only delete OPEN jobs");

        if (amount > 0) {
            escrowedFunds[_jobId] = 0;
            (bool success, ) = job.employer.call{value: amount}("");
            require(success, "JobBoard: Refund during delete failed");
            emit EmployerRefunded(_jobId, job.employer, amount);
        }
        job.status = JobStatus.DELETED;
        emit JobDeleted(_jobId);
    }

    /**
     * @notice Allows the assigned freelancer to withdraw their application (unassign).
     */
    function withdrawApplication(uint256 _jobId) public jobExistsAndActive(_jobId) onlyFreelancer(_jobId) nonReentrant {
        Job storage job = jobs[_jobId];
        require(job.status == JobStatus.ASSIGNED, "JobBoard: Can only withdraw when ASSIGNED");

        address freelancerAddress = job.freelancer;
        job.freelancer = payable(address(0));
        job.status = JobStatus.OPEN; // Job becomes open again
        emit ApplicationWithdrawn(_jobId, freelancerAddress);
    }

    /**
     * @notice Allows employer or freelancer to raise a dispute on ASSIGNED or AWAITING_APPROVAL jobs.
     */
    function raiseDispute(uint256 _jobId) public jobExistsAndActive(_jobId) {
        Job storage job = jobs[_jobId];
        require(msg.sender == job.employer || msg.sender == job.freelancer, "JobBoard: Only participants can raise dispute");
        require(job.status == JobStatus.ASSIGNED || job.status == JobStatus.AWAITING_APPROVAL, "JobBoard: Invalid status for dispute");
        job.status = JobStatus.DISPUTED;
        emit DisputeRaised(_jobId, msg.sender);
    }

    /**
     * @notice Allows the contract owner (admin) to resolve a dispute.
     */
    function resolveDispute(uint256 _jobId, bool _awardToFreelancer) public onlyOwner nonReentrant {
        // Admin might need to resolve jobs even if marked deleted, so don't use jobExistsAndActive
         require(_jobId > 0 && _jobId <= jobCount, "JobBoard: Job does not exist");
        Job storage job = jobs[_jobId];
        uint256 amount = escrowedFunds[_jobId];
        require(job.status == JobStatus.DISPUTED, "JobBoard: Job not in dispute");
        require(amount > 0, "JobBoard: No funds in escrow");

        escrowedFunds[_jobId] = 0;
        address payable winner;
        bool success;
        if (_awardToFreelancer) {
            require(job.freelancer != address(0), "JobBoard: No freelancer to award");
            winner = job.freelancer;
            job.status = JobStatus.COMPLETED; // Final status
            (success, ) = winner.call{value: amount}("");
            require(success, "JobBoard: Dispute payment failed");
            emit PaymentReleased(_jobId, winner, amount);
        } else {
            winner = job.employer;
            job.status = JobStatus.REFUNDED; // Final status
            (success, ) = winner.call{value: amount}("");
            require(success, "JobBoard: Dispute refund failed");
            emit EmployerRefunded(_jobId, winner, amount);
        }
        emit DisputeResolved(_jobId, msg.sender, winner, amount);
    }

    // --- View Functions ---
    function getJobCount() public view returns (uint256) { return jobCount; }
    function getJob(uint256 _jobId) public view jobExistsAndActive(_jobId) returns (Job memory) { return jobs[_jobId]; }
    function getEscrowAmount(uint256 _jobId) public view jobExistsAndActive(_jobId) returns (uint256) { return escrowedFunds[_jobId]; }
}