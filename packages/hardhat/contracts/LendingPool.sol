// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "../axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol";
//@axelar-network/axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol
import "../axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGasService.sol";
//axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGasService.sol
import "./RWAOracle.sol";

contract LendingPool is AxelarExecutable, ReentrancyGuard, Ownable {
    //Add state variables and structs next
    IERC20Metadata public lendingToken;
    ERC721 public rwaToken;
    RWAOracle public rwaOracle;
    IAxelarGasService public immutable gasService;

    uint256 public constant LIQUIDATION_THRESHOLD = 150;
    uint256 public constant INTERSEST_RATE = 5;
    
    string public sourceAddress;
    string public sourceChain;

    struct Loan {
        uint256 amount;
        uint256 collateralId;
        uint256 startTime;
        uint256 duration;
        address borrower;
        bool isActive;
    }

    mapping(uint256 => Loan) public loans;
    uint256 public nextLoanId;

    event LoanCreated(
        uint256 loanId,
        address borrower,
        uint256 amount,
        uint256 collateralId
    );
    event LoanRepaid(uint256 loanId);
    event LoanLiquidated(uint256 loanId, address liquidator);

    event CrossChainLoanRepaid(uint256 loanId);
    event CollateralReleased(
          uint256 loanId,
          uint256 collateralId,
          address borrower
    );

    constructor(
        address _initialOwner,
        address _gateway,
        address _lendingToken,
        address _rwaToken,
        address _rwaOracle,
        address _gasService
    ) AxelarExecutable(_gateway) Ownable(_initialOwner) {
        gasService = IAxelarGasService(address(_gasService));
        lendingToken = IERC20Metadata(_lendingToken);
        rwaToken = ERC721(_rwaToken);
        rwaOracle = RWAOracle(_rwaOracle);
    }

    function createLoan(
        uint256 _amount,
        uint256 _collateralId,
        uint256 _duration
    ) external nonReentrant {
        require(
            rwaToken.ownerOf(_collateralId) == msg.sender,
            "Not the owner of the RWA"
        );

        uint256 collateralValue = rwaOracle.getRWAValue(_collateralId);
        require(
            (collateralValue * 100) / _amount >= LIQUIDATION_THRESHOLD,
            "Insufficient collateral"
        );

        uint256 loanId = nextLoanId++;
        loans[loanId]= Loan({
            amount: _amount,
            collateralId: _collateralId,
            startTime: block.timestamp,
            duration: _duration,
            borrower: msg.sender,
            isActive: true
        });

        rwaToken.transferFrom(msg.sender, address(this), _collateralId);
        require(lendingToken.transfer(msg.sender, _amount), "Transfer failed");

        emit LoanCreated(loanId, msg.sender, _amount, _collateralId);
    }

    // Create repayment function

    function repayLoan(uint256 _loanId) external nonReentrant {
       Loan storage loan =loans[_loanId];
       require (loan.isActive, "Loan is not active");
       require (loan.borrower == msg.sender, "Not the borrower");
       
       uint256 interest = calculateInterest(
        loan.amount, 
        loan.startTime, 
        loan.duration
       );
       uint256 totalRepayment = loan.amount + interest;

       require(
            lendingToken.transferFrom(
                msg.sender,
                address(this),
                totalRepayment

            ),
            "Transfer failed"
       );

       rwaToken.transferFrom(address(this), msg.sender, loan.collateralId);
       loan.isActive = false;

       emit LoanRepaid(_loanId);

    }

    //Calculate interest
    function calculateInterest(
        uint256 _amount,
        uint256 _startTime,
        uint256 _duration
    ) public view returns (uint256) {
        uint256 timeElapsed = block.timestamp - _startTime;

        //Cap the time elapsed to the loan duratu\ion
        if (timeElapsed > _duration) {
            timeElapsed = _duration;
    }

    //Calculate interest: (amount * rate * time) / (365 days * 100 * 10^decimals)
    // For a 5% annual rate
    uint256 interest = (_amount * 5* timeElapsed) /(356 days * 100);

    //Adjust for token decimals (assuming 6 decimals for USDC)
    return interest / 1e6;
    }
    
    //Liquidate loan

    function initiateCrossChainLoan(
        string memory destinationChain,
        string memory destinationAddress,
        uint256 _amount,
        uint256 _collateralId,
        uint256 _duration
        
    ) external payable {
        require(msg.value > 0, "Gas payment is required");
        require(
            rwaToken.ownerOf(_collateralId) == msg.sender,
            "Not the owner of the RWA"
        );

        uint256 collateralValue = rwaOracle.getRWAValue(_collateralId);
        require(
            (collateralValue * 100) / _amount >= LIQUIDATION_THRESHOLD,
            "Insufficient collateral"
        );

        bytes memory payload = abi.encode(
            msg.sender,
            _amount,
            _collateralId,
            _duration
        );

        gasService.payNativeGasForContractCallWithToken{value: msg.value}(
            address(this),
            destinationChain,
            destinationAddress,
            payload,
            lendingToken.symbol(),
            _amount,
            msg.sender
        );

        rwaToken.transferFrom(msg.sender, address(this), _collateralId);
        lendingToken.transferFrom(msg.sender, address(this), _amount);
        lendingToken.approve(address(gateway), _amount);

        gateway.callContractWithToken(
            destinationChain,
            destinationAddress,
            payload,
            lendingToken.symbol(),
            _amount
        );


    }

    function _executeWithToken(
        string calldata _sourceChain,
        string calldata _sourceAddress,
        bytes calldata payload,
        string calldata tokenSymbol,
        uint256 
     ) internal override {
        require(
            keccak256(bytes(tokenSymbol)) == 
              keccak256(bytes(lendingToken.symbol())),
            "Invalid token"
        );

        sourceAddress = _sourceAddress;
        sourceChain = _sourceChain;

        (
            address borrower,
            uint256 _amount,
            uint256 _collateralId,
            uint256 _duration
        ) = abi.decode (payload, (address, uint256, uint256, uint256));

        //Create the loan

        uint256 loanId = _createLoanInternal(
            borrower, 
            _amount, 
            _collateralId, 
            _duration
        );

        require(lendingToken.transfer(borrower, _amount), "Transfer failed");

        emit LoanCreated(loanId, borrower, _amount, _collateralId);
    }

    function _createLoanInternal(
        address borrower,
        uint256 _amount,
        uint256 _collateralId,
        uint256 _duration
    )
        internal 
        returns (
            uint256
        )
    {
       uint256 loanId = nextLoanId++;
       loans[loanId] = Loan({
        amount : _amount,
        collateralId: _collateralId,
        startTime: block.timestamp,
        duration: _duration,
        borrower: borrower,
        isActive: true
       });
       return loanId; 
    }

    // On the destination cvhain 
    function repayCrossChainLoan(
        uint256 _loanId,
        string memory destinationChain,
        string memory destinationAddress
    ) external payable nonReentrant {

        require(msg.value > 0, "Gas payment is required");

        Loan storage loan = loans[_loanId];
        require(loan.isActive, "Loan is not active");
        require(loan.borrower == msg.sender, "Not the borrower");

        uint256 interest = calculateInterest(
            loan.amount, 
            loan.startTime, 
            loan.duration
        );
        uint256 totalRepayment = loan.amount + interest;

        require(
            lendingToken.transferFrom(
                msg.sender,
                address(this),
                totalRepayment
            ),
            "Transfer failed"
        );

        loan.isActive = false;

        // Send message to source chain to release collateral
        bytes memory payload = abi.encode(
            _loanId,
            loan.collateralId,
            loan.borrower
        );

        gasService.payNativeGasForContractCallWithToken{value: msg.value}(
            address(this),
            destinationChain,
            destinationAddress,
            payload,
            lendingToken.symbol(),
            loan.amount,
            msg.sender

        );

        gateway.callContract(sourceChain, sourceAddress, payload);

        emit CrossChainLoanRepaid(_loanId);
    }
} 
//@1:07:303