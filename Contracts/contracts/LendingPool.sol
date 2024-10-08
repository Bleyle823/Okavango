// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "@axelar-network/axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol";
import "@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGasService.sol";

import "./RWAOracle.sol";

contract LendingPool is AxelarExecutable, ReentrancyGuard, Ownable{

    //we'll add state variables and structs next
    IERC20Metadata public lendingToken;
    ERC721 public rwaToken;
    RWAOracle public rwaOracle;
    IAxelarGasService public immutable gasService;

    uint256 public constant LIQUIDATION_THRESHOLD = 150;
    uint256 public constant INTEREST_RATE = 5; // 5% ANNUAL INTEREST RATE

    string public sourceAddress;
    string public sourceChain;

    struct Loan {
        uint256 amount;
        uint256 collateralId;
        uint256 startTime;
        uint256 duration;
        uint256 borrower;
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
    event LoanRepaid(uint256 loandId);
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
        // string memory _sourceAddress,
        // string memory _sourceChain
        
        ) AxelarExecutable(_initialOwner) {
        gasService = IAxelarGasService(_gasService);
        // sourceAddress = _sourceAddress;
        // sourceChain = _sourceChain;
        lendingToken = IERC20Metadata(_lendingToken);
        rwaToken = ERC721(_rwaToken);
        rwaOracle = RWAOracle(_rwaOracle);
    }
        //loan creation function

        function createLoan(
        uint256 _amount,
        uint256 _collateralId,
        uint256 _duration
    ) external nonReentrant {
        // Ensure the caller is the owner of the RWA token being used as collateral
        require(
            rwaToken.ownerOf(_collateralId) == msg.sender,
            "Not the owner of the RWA"
        );

        // Get the collateral value from the oracle
        uint256 collateralValue = rwaOracle.getRWAValue(_collateralId);

        // Ensure that the collateral ratio meets or exceeds the liquidation threshold
        require(
            (collateralValue * 100) / _amount >= LIQUIDATION_THRESHOLD,
            "Insufficient collateral"
        );

        // Create a new loan ID and increment the counter
        uint256 loanId = nextLoanId;
        nextLoanId++;

        // Store the loan details in the loans mapping
        loans[loanId] = Loan({
            amount: _amount,
            collateralId: _collateralId,
            startTime: block.timestamp,
            duration: _duration,
            borrower: msg.sender,
            isActive: true
        });

        // Transfer the RWA token (collateral) to the contract
        rwaToken.transferFrom(msg.sender, address(this), _collateralId);

        // Transfer the loan amount in lending tokens to the borrower
        require(
            lendingToken.transfer(msg.sender, _amount),
            "Loan transfer failed"
        );

        // Emit an event to log the loan creation
        emit LoanCreated(loanId, msg.sender, _amount, _collateralId);
    }
        // Create repayment function

      function repayLoan(uint256 _loanId) external nonReentrant {
        Loan storage loan = loans[_loanId];

        // Ensure that the loan is active and that the caller is the borrower
        require(loan.isActive, "Loan is not active");
        require(loan.borrower == msg.sender, "Not the borrower");

        // Calculate the interest based on loan details
        uint256 interest = calculateInterest(
            loan.amount, 
            loan.startTime, 
            loan.duration
        );

        // Total amount required for repayment (principal + interest)
        uint256 totalRepayment = loan.amount + interest;

        // Borrower must transfer the total repayment amount to the contract
        require(
            lendingToken.transferFrom(
                msg.sender,    // Borrower (who repays the loan)
                address(this), // This contract (lender)
                totalRepayment
            ),
            "Loan repayment transfer failed"
        );

        // Return the collateral (RWA token) to the borrower
        rwaToken.transferFrom(address(this), msg.sender, loan.collateralId);

        // Mark the loan as repaid (inactive)
        loan.isActive = false;

        // Emit an event to notify that the loan has been repaid
        emit LoanRepaid(_loanId);
    }

        //Calculate Interest

        function calculateInterest(
            uint256 _amount,
            uint256 _startTime,
            uint256 _duration
        ) public view returns (uint256) {
            uint256 timeElapsed =block.timestamp - _startTime;

            //Cap the time elapsed to the loan duration

            if (timeElapsed > _duration) {
                timeElapsed = _duration;
            }

            //Calculated interested: (amount * rate * time) (365 days * 100 * 10^decimals)
            //for a 5% annual rate

            uint256 interest = (_amount * 5 * timeElapsed) / (365 days * 100);

            // Adjust for token decimals (assuming 6 decimals for USDC)
            return interest /1e6;
        }

        //liquidate

        function initiateCrossChain(
            string memory destinationChain,
            string memory destinationAddress,
            uint256 _amount,
            uint256 _collateralId,
            uint256 _duration 
            ) external payable  {
            require(msg.value > 0, "gas payment is required");
            require(
                rwaToken.ownerOf(_collateralId) == msg.sender,
                "Not the owner of the RWA" 
            );
            uint256 collateralValue = rwaOracle.getRWAValue(_collateralId);
            require(collateralValue * 100 / _amount >= LIQUIDATION_THRESHOLD, 
            "Insufficient collateral" 
            );
            
            bytes memory payload = abi.encode(
                msg.sender,
                _amount, 
                _collateralId, 
                _duration

            );

            gasService.payNativeGasForContractCallWithToken{value: msg.value}(
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
            
            // uint256 interest = calculateInterest(
            //     _amount, 
            //     block.timestamp, 
            //     _duration, 
            // );
            // uint256 totalRepayment = _amount + interest;
            // require(lendingToken.transferFrom(msg.sender, address(this), _collateralId), 
            // "Transfer failed" 
            // );
            // rwaToken.transferFrom(address(this), msg.sender, _collateralId);
            // emit CollateralReleased(_amount, _collateralId, msg.sender);
            }
  
        function _executeWithToken(
            string calldata _sourceChain,
            string calldata _sourceAddress,
            bytes calldata _payload, 
            string calldata _tokenSymbol, 
            uint256 
        ) internal override {
            require(
                keccak256(bytes(_tokenSymbol)) ==
                   keccak256(bytes(lendingToken.symbol())),
                   "invalid token"

            );

            sourceAddress = _sourceAddress;
            sourceChain = _sourceChain;

        (
            address borrower,
            uint256 _amount,
            uint256 _collateralId, 
            uint256 _duration,
        ) = abi.decode(payload, (address, uint256, uint256, uint256));

        //create the loan 

        }
        
        function _createLoanInternal(
            address borrower,
            uint256 _amount,
            uint256 _collateralId, 
            uint256 _duration
        )
            internal 
            returns(
                uint256
            )
        {
            uint256 loanId = nextLoanId++;
            loans[loanId] = Loan({
                amount: _amount,
                collateralId: _collateralId,
                startTime: block.timestamp,
                duration: _duration,
                borrower: borrower,
                isActive: true
            });
            return loanId;
        }
}
