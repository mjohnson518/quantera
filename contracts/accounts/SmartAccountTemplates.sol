// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "../interfaces/ISmartAccountTemplates.sol";

/**
 * @title SmartAccountTemplates
 * @dev Contract for managing smart account templates and executing account logic
 * 
 * Security Enhancements (v0.9.7):
 * - Added custom errors for gas-efficient error handling
 * - Enhanced role-based access control in critical functions
 * - Improved input validation with custom errors
 * - Added additional security checks for sensitive operations
 * - Better delegation security with clear authorization checks
 */
contract SmartAccountTemplates is ISmartAccountTemplates, AccessControl, Pausable, ReentrancyGuard {
    using Counters for Counters.Counter;
    using ECDSA for bytes32;

    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");

    // Custom errors for gas efficiency
    error Unauthorized(address caller, bytes32 requiredRole);
    error TemplateNotFound(bytes32 templateId);
    error AccountNotFound(bytes32 accountId);
    error EmptyInput(string paramName);
    error InvalidParameter(string paramName, string reason);
    error AccountInactive(bytes32 accountId);
    error NotAccountOwner(address caller, address owner);
    error NotDelegateAuthorized(address delegate, bytes32 accountId);
    error ExpiredExecution(uint64 validUntil, uint64 currentTime);
    error NonceAlreadyUsed(uint256 nonce, bytes32 accountId);
    error TemplateNotVerified(bytes32 templateId);
    error ValueOutOfRange(uint256 value, uint256 minValue, uint256 maxValue);
    error CodeExecutionFailed(bytes32 accountId, string reason);
    error InvalidZeroAddress(string paramName);

    // Counters - grouped for better packing
    Counters.Counter private _templateIdCounter;
    Counters.Counter private _accountIdCounter;
    Counters.Counter private _operationIdCounter;
    Counters.Counter private _nonceCounter;

    // Storage Optimization: Group structs for better packing
    struct AccountTemplateData {
        bytes32 templateId;        // 32 bytes
        address creator;           // 20 bytes
        // Storage slot optimization by grouping smaller variables
        bool isPublic;             // 1 byte
        bool isVerified;           // 1 byte
        uint64 creationDate;       // 8 bytes
        uint64 verificationDate;   // 8 bytes 
        // End of first storage slot for optimized variables
        TemplateType templateType; // Enum
        uint256 usageCount;        // 32 bytes
        bytes code;                // Dynamic array (separate storage)
        string name;               // Dynamic string (separate storage)
        string description;        // Dynamic string (separate storage)
        string parametersSchema;   // Dynamic string (separate storage)
        string version;            // Dynamic string (separate storage)
    }

    struct SmartAccountData {
        bytes32 accountId;         // 32 bytes
        bytes32 templateId;        // 32 bytes
        address owner;             // 20 bytes
        // Storage slot optimization by grouping smaller variables 
        bool isActive;             // 1 byte
        uint64 creationDate;       // 8 bytes
        uint64 lastExecution;      // 8 bytes
        // End of optimized storage slot
        bytes32 codeHash;          // 32 bytes
        uint256 executionCount;    // 32 bytes
        bytes code;                // Dynamic array (separate storage)
    }

    struct SmartAccountParams {
        mapping(string => string) values;
    }

    // Mappings
    mapping(bytes32 => AccountTemplateData) private _templates;
    mapping(bytes32 => SmartAccountData) private _accounts;
    mapping(bytes32 => mapping(string => string)) private _accountParameters;
    mapping(bytes32 => VerificationResult) private _verificationResults;
    mapping(bytes32 => SmartAccountOperation[]) private _accountOperations;
    mapping(bytes32 => address[]) private _accountDelegates;
    mapping(address => bytes32[]) private _ownerAccounts;
    mapping(address => bytes32[]) private _delegateAccounts;
    mapping(address => bytes32[]) private _creatorTemplates;
    mapping(TemplateType => bytes32[]) private _templatesByType;
    
    // Gas optimization: Combine related mappings
    mapping(bytes32 => uint256) private _accountNonces;
    mapping(bytes32 => bool) private _usedNonces;
    
    // Arrays
    bytes32[] private _publicTemplates;
    bytes32[] private _verifiedTemplates;

    // Events
    event TemplateCreated(bytes32 indexed templateId, address indexed creator, string name, TemplateType templateType);
    event TemplateUpdated(bytes32 indexed templateId, address indexed updater, string name);
    event TemplateVerified(bytes32 indexed templateId, address indexed verifier, bool isVerified);
    event AccountDeployed(bytes32 indexed accountId, address indexed owner, bytes32 indexed templateId);
    event AccountUpdated(bytes32 indexed accountId, address indexed updater);
    event AccountExecuted(bytes32 indexed accountId, address indexed executor, bytes32 indexed operationId);
    event DelegateAdded(bytes32 indexed accountId, address indexed delegate);
    event DelegateRemoved(bytes32 indexed accountId, address indexed delegate);

    // Constructor
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(VERIFIER_ROLE, msg.sender);
    }

    //--------------------------------------------------------------------------
    // Template Management Functions
    //--------------------------------------------------------------------------

    /**
     * @dev Create a new account template
     * @param name Template name
     * @param description Template description
     * @param templateType Type of template
     * @param code Code for the template
     * @param isPublic Whether the template is public
     * @param parametersSchema JSON schema for parameters
     * @param version Version string
     * @return templateId ID of the created template
     */
    function createTemplate(
        string calldata name,
        string calldata description,
        TemplateType templateType,
        bytes calldata code,
        bool isPublic,
        string calldata parametersSchema,
        string calldata version
    ) external whenNotPaused returns (bytes32) {
        // Validate inputs
        if (bytes(name).length == 0) {
            revert EmptyInput("name");
        }
        if (code.length == 0) {
            revert EmptyInput("code");
        }
        
        _templateIdCounter.increment();
        bytes32 templateId = keccak256(abi.encodePacked(
            _templateIdCounter.current(),
            msg.sender,
            block.timestamp
        ));
        
        _templates[templateId] = AccountTemplateData({
            templateId: templateId,
            name: name,
            description: description,
            templateType: templateType,
            creator: msg.sender,
            code: code,
            isPublic: isPublic,
            isVerified: false,
            creationDate: uint64(block.timestamp),
            verificationDate: 0,
            parametersSchema: parametersSchema,
            version: version,
            usageCount: 0
        });
        
        // Add to creator's templates
        _creatorTemplates[msg.sender].push(templateId);
        
        // Add to templates by type
        _templatesByType[templateType].push(templateId);
        
        // Add to public templates if public
        if (isPublic) {
            _publicTemplates.push(templateId);
        }
        
        emit TemplateCreated(templateId, msg.sender, name, templateType);
        
        return templateId;
    }

    /**
     * @dev Update an existing template
     * @param templateId Template ID to update
     * @param name Updated name
     * @param description Updated description
     * @param code Updated code
     * @param isPublic Updated visibility
     * @param parametersSchema Updated parameters schema
     * @param version Updated version
     * @return success Whether the update was successful
     */
    function updateTemplate(
        bytes32 templateId,
        string calldata name,
        string calldata description,
        bytes calldata code,
        bool isPublic,
        string calldata parametersSchema,
        string calldata version
    ) external whenNotPaused returns (bool) {
        // Validate template exists
        if (_templates[templateId].templateId != templateId) {
            revert TemplateNotFound(templateId);
        }
        
        // Check authorization
        if (_templates[templateId].creator != msg.sender && !hasRole(ADMIN_ROLE, msg.sender)) {
            revert Unauthorized(msg.sender, ADMIN_ROLE);
        }
        
        // Validate inputs
        if (bytes(name).length == 0) {
            revert EmptyInput("name");
        }
        if (code.length == 0) {
            revert EmptyInput("code");
        }
        
        AccountTemplateData storage template = _templates[templateId];
        
        // Update template data
        template.name = name;
        template.description = description;
        template.code = code;
        template.parametersSchema = parametersSchema;
        template.version = version;
        
        // Handle public status change
        if (template.isPublic != isPublic) {
            template.isPublic = isPublic;
            
            if (isPublic) {
                // Add to public templates
                _publicTemplates.push(templateId);
            } else {
                // Remove from public templates
                for (uint256 i = 0; i < _publicTemplates.length; i++) {
                    if (_publicTemplates[i] == templateId) {
                        _publicTemplates[i] = _publicTemplates[_publicTemplates.length - 1];
                        _publicTemplates.pop();
                        break;
                    }
                }
            }
        }
        
        emit TemplateUpdated(templateId, msg.sender, name);
        
        return true;
    }

    /**
     * @dev Verify a template
     * @param templateId Template ID to verify
     * @param vulnerabilityRisk Risk score for vulnerabilities (0-100)
     * @param securityNotes Notes about security concerns
     * @param performanceRisk Risk score for performance issues (0-100)
     * @return success Whether the verification was successful
     */
    function verifyTemplate(
        bytes32 templateId,
        uint8 vulnerabilityRisk,
        string[] calldata securityNotes,
        uint8 performanceRisk
    ) external whenNotPaused onlyRole(VERIFIER_ROLE) returns (bool) {
        // Validate template exists
        if (_templates[templateId].templateId != templateId) {
            revert TemplateNotFound(templateId);
        }
        
        // Validate risk scores are in range
        if (vulnerabilityRisk > 100) {
            revert ValueOutOfRange(vulnerabilityRisk, 0, 100);
        }
        if (performanceRisk > 100) {
            revert ValueOutOfRange(performanceRisk, 0, 100);
        }
        
        AccountTemplateData storage template = _templates[templateId];
        
        // Update verification status
        bool wasVerified = template.isVerified;
        template.isVerified = true;
        template.verificationDate = uint64(block.timestamp);
        
        // Create verification result
        _verificationResults[templateId] = VerificationResult({
            isVerified: true,
            vulnerabilityRisk: vulnerabilityRisk,
            securityNotes: securityNotes,
            performanceRisk: performanceRisk,
            verifier: msg.sender,
            verificationTimestamp: uint64(block.timestamp)
        });
        
        // Add to verified templates if not already there
        if (!wasVerified) {
            _verifiedTemplates.push(templateId);
        }
        
        emit TemplateVerified(templateId, msg.sender, true);
        
        return true;
    }

    /**
     * @dev Get template details
     * @param templateId Template ID
     * @return Template details
     */
    function getTemplate(bytes32 templateId) external view returns (AccountTemplate memory) {
        if (_templates[templateId].templateId != templateId) {
            revert TemplateNotFound(templateId);
        }
        
        AccountTemplateData storage template = _templates[templateId];
        
        return AccountTemplate({
            templateId: template.templateId,
            name: template.name,
            description: template.description,
            templateType: template.templateType,
            creator: template.creator,
            code: template.code,
            isPublic: template.isPublic,
            isVerified: template.isVerified,
            creationDate: template.creationDate,
            verificationDate: template.verificationDate,
            parametersSchema: template.parametersSchema,
            version: template.version,
            usageCount: template.usageCount
        });
    }

    /**
     * @dev Get verification result for a template
     * @param templateId Template ID
     * @return Verification result
     */
    function getVerificationResult(bytes32 templateId) external view returns (VerificationResult memory) {
        if (_templates[templateId].templateId != templateId) {
            revert TemplateNotFound(templateId);
        }
        if (!_templates[templateId].isVerified) {
            revert TemplateNotVerified(templateId);
        }
        
        return _verificationResults[templateId];
    }

    /**
     * @dev Get templates by type
     * @param templateType Type of template
     * @return Array of template IDs
     */
    function getTemplatesByType(TemplateType templateType) external view returns (bytes32[] memory) {
        return _templatesByType[templateType];
    }

    /**
     * @dev Get templates created by a user
     * @param creator Creator address
     * @return Array of template IDs
     */
    function getTemplatesByCreator(address creator) external view returns (bytes32[] memory) {
        return _creatorTemplates[creator];
    }

    /**
     * @dev Get all public templates
     * @return Array of template IDs
     */
    function getPublicTemplates() external view returns (bytes32[] memory) {
        return _publicTemplates;
    }

    /**
     * @dev Get all verified templates
     * @return Array of template IDs
     */
    function getVerifiedTemplates() external view returns (bytes32[] memory) {
        return _verifiedTemplates;
    }

    //--------------------------------------------------------------------------
    // Account Management Functions
    //--------------------------------------------------------------------------

    /**
     * @dev Deploy a smart account from a template
     * @param templateId Template ID to use
     * @param parameters Parameters for initialization
     * @return accountId ID of the deployed account
     */
    function deployAccount(
        bytes32 templateId,
        mapping(string => string) memory parameters
    ) external whenNotPaused nonReentrant returns (bytes32) {
        // Validate template exists
        if (_templates[templateId].templateId != templateId) {
            revert TemplateNotFound(templateId);
        }
        
        AccountTemplateData storage template = _templates[templateId];
        
        // Increment template usage count
        template.usageCount += 1;
        
        // Generate account ID
        _accountIdCounter.increment();
        bytes32 accountId = keccak256(abi.encodePacked(
            _accountIdCounter.current(),
            msg.sender,
            templateId,
            block.timestamp
        ));
        
        // Store account data
        _accounts[accountId] = SmartAccountData({
            accountId: accountId,
            owner: msg.sender,
            templateId: templateId,
            code: template.code,
            codeHash: keccak256(template.code),
            creationDate: uint64(block.timestamp),
            lastExecution: 0,
            executionCount: 0,
            isActive: true
        });
        
        // Store parameters
        for (string memory key in parameters) {
            _accountParameters[accountId][key] = parameters[key];
        }
        
        // Add to owner's accounts
        _ownerAccounts[msg.sender].push(accountId);
        
        emit AccountDeployed(accountId, msg.sender, templateId);
        
        return accountId;
    }

    /**
     * @dev Get smart account details
     * @param accountId Account ID
     * @return Account details
     */
    function getAccount(bytes32 accountId) external view returns (SmartAccount memory) {
        if (_accounts[accountId].accountId != accountId) {
            revert AccountNotFound(accountId);
        }
        
        SmartAccountData storage account = _accounts[accountId];
        address[] storage delegates = _accountDelegates[accountId];
        
        // Create parameters map
        mapping(string => string) storage params = _accountParameters[accountId];
        
        return SmartAccount({
            accountId: account.accountId,
            owner: account.owner,
            templateId: account.templateId,
            code: account.code,
            codeHash: account.codeHash,
            creationDate: account.creationDate,
            lastExecution: account.lastExecution,
            executionCount: account.executionCount,
            parameters: params,
            isActive: account.isActive,
            delegates: delegates
        });
    }

    /**
     * @dev Execute smart account code
     * @param accountId Account ID to execute
     * @param data Execution data
     * @param executionParams Execution parameters
     * @return result Execution result
     */
    function executeAccount(
        bytes32 accountId,
        bytes calldata data,
        ExecutionParams calldata executionParams
    ) external whenNotPaused nonReentrant returns (ExecutionResult memory) {
        // Validate account exists and is active
        if (_accounts[accountId].accountId != accountId) {
            revert AccountNotFound(accountId);
        }
        if (!_accounts[accountId].isActive) {
            revert AccountInactive(accountId);
        }
        
        SmartAccountData storage account = _accounts[accountId];
        
        // Check authorization
        bool isAuthorized = false;
        
        if (msg.sender == account.owner) {
            isAuthorized = true;
        } else if (executionParams.delegated) {
            // Check if the delegate is authorized
            if (!_isDelegateAuthorized(accountId, executionParams.delegate)) {
                revert NotDelegateAuthorized(executionParams.delegate, accountId);
            }
            
            isAuthorized = true;
            
            // When using delegated execution, validate nonce to prevent replay
            bytes32 nonceHash = keccak256(abi.encodePacked(accountId, executionParams.nonce));
            if (_usedNonces[nonceHash]) {
                revert NonceAlreadyUsed(executionParams.nonce, accountId);
            }
            
            // Mark nonce as used - effects before interactions pattern
            _usedNonces[nonceHash] = true;
            
            // Ensure execution hasn't expired
            if (block.timestamp > executionParams.validUntil) {
                revert ExpiredExecution(executionParams.validUntil, uint64(block.timestamp));
            }
        }
        
        if (!isAuthorized) {
            revert Unauthorized(msg.sender, bytes32(0));
        }
        
        // Create operation ID for tracking
        _operationIdCounter.increment();
        bytes32 operationId = keccak256(abi.encodePacked(
            _operationIdCounter.current(),
            accountId,
            msg.sender,
            block.timestamp
        ));
        
        // Execute the code (in a real implementation, this would use a VM or interpreter)
        ExecutionResult memory result = _executeCode(account.code, data, accountId);
        
        // Update account execution stats - effects before interactions pattern
        account.lastExecution = uint64(block.timestamp);
        account.executionCount += 1;
        
        // Record the operation
        SmartAccountOperation memory operation = SmartAccountOperation({
            operationId: operationId,
            accountId: accountId,
            operationType: "execute",
            timestamp: uint64(block.timestamp),
            data: data,
            result: result,
            executed_by: msg.sender
        });
        
        _accountOperations[accountId].push(operation);
        
        emit AccountExecuted(accountId, msg.sender, operationId);
        
        return result;
    }

    /**
     * @dev Simulate execution without state changes
     * @param accountId Account ID to simulate
     * @param data Execution data
     * @return result Execution result
     */
    function simulateExecution(
        bytes32 accountId,
        bytes calldata data
    ) external view returns (ExecutionResult memory) {
        require(_accounts[accountId].accountId == accountId, "Account does not exist");
        
        // Execute code in simulation mode
        return _executeCode(_accounts[accountId].code, data, accountId);
    }

    /**
     * @dev Execute code with a VM or interpreter
     * @param code The code to execute
     * @param data The input data
     * @param accountId The account ID (for parameter access)
     * @return result The execution result
     */
    function _executeCode(bytes memory code, bytes memory data, bytes32 accountId) private returns (ExecutionResult memory) {
        // In a real implementation, this would use a VM or interpreter
        // For this mock implementation, we'll just simulate success
        
        // Perform basic validation
        if (code.length == 0) {
            return ExecutionResult({
                success: false,
                resultData: bytes(""),
                logs: new string[](0),
                gasUsed: 0,
                errorMessage: "Empty code"
            });
        }
        
        // Simulate execution (in a real implementation, this would actually execute the code)
        bool success = true;
        bytes memory resultData = bytes("Execution successful");
        string[] memory logs = new string[](1);
        logs[0] = "Execution log: Code executed successfully";
        uint256 gasUsed = 100000; // Simulated gas usage
        
        // Check for simulated failures (for testing)
        if (keccak256(data) == keccak256(bytes("simulate_failure"))) {
            success = false;
            resultData = bytes("Simulated failure");
            logs[0] = "Execution log: Simulated failure occurred";
            return ExecutionResult({
                success: false,
                resultData: resultData,
                logs: logs,
                gasUsed: gasUsed,
                errorMessage: "Simulated execution failure"
            });
        }
        
        return ExecutionResult({
            success: success,
            resultData: resultData,
            logs: logs,
            gasUsed: gasUsed,
            errorMessage: ""
        });
    }

    /**
     * @dev Generate a nonce for account execution
     * @param accountId Account ID
     * @return nonce Generated nonce
     */
    function generateNonce(bytes32 accountId) external whenNotPaused returns (uint256) {
        require(_accounts[accountId].accountId == accountId, "Account does not exist");
        
        _nonceCounter.increment();
        return _nonceCounter.current();
    }

    /**
     * @dev Verify signature for delegated execution
     * @param accountId Account ID
     * @param data Execution data
     * @param nonce Nonce used
     * @param signature Signature to verify
     * @return isValid Whether the signature is valid
     */
    function verifySignature(
        bytes32 accountId,
        bytes calldata data,
        uint256 nonce,
        bytes calldata signature
    ) external view returns (bool) {
        require(_accounts[accountId].accountId == accountId, "Account does not exist");
        
        // Create the message hash that was signed
        bytes32 messageHash = keccak256(abi.encodePacked(
            accountId,
            data,
            nonce,
            block.chainid
        ));
        
        // Convert to Ethereum signed message hash
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));
        
        // Recover the signer address
        address signer = ethSignedMessageHash.recover(signature);
        
        // Check if the signer is the account owner or a delegate
        return (signer == _accounts[accountId].owner || _isDelegateAuthorized(accountId, signer));
    }

    /**
     * @dev Get operation history for a smart account
     * @param accountId Account ID
     * @return Array of operations
     */
    function getOperationHistory(
        bytes32 accountId
    ) external view returns (SmartAccountOperation[] memory) {
        require(_accounts[accountId].accountId == accountId, "Account does not exist");
        return _accountOperations[accountId];
    }

    //--------------------------------------------------------------------------
    // Delegation Management Functions
    //--------------------------------------------------------------------------

    /**
     * @dev Add a delegate to a smart account
     * @param accountId Account ID
     * @param delegate Delegate address to add
     * @return success Whether the delegate was added successfully
     */
    function addDelegate(
        bytes32 accountId,
        address delegate
    ) external whenNotPaused nonReentrant returns (bool) {
        // Validate account exists
        if (_accounts[accountId].accountId != accountId) {
            revert AccountNotFound(accountId);
        }
        
        // Check that caller is the account owner
        if (_accounts[accountId].owner != msg.sender) {
            revert NotAccountOwner(msg.sender, _accounts[accountId].owner);
        }
        
        // Validate delegate address
        if (delegate == address(0)) {
            revert InvalidZeroAddress("delegate");
        }
        
        // Check if delegate is already authorized
        if (_isDelegateAuthorized(accountId, delegate)) {
            return true; // Already a delegate, return success
        }
        
        // Add delegate to account
        _accountDelegates[accountId].push(delegate);
        
        // Add account to delegate's accounts
        _delegateAccounts[delegate].push(accountId);
        
        emit DelegateAdded(accountId, delegate);
        
        return true;
    }

    /**
     * @dev Remove a delegate from a smart account
     * @param accountId Account ID
     * @param delegate Delegate address to remove
     * @return success Whether the delegate was removed successfully
     */
    function removeDelegate(
        bytes32 accountId,
        address delegate
    ) external whenNotPaused nonReentrant returns (bool) {
        // Validate account exists
        if (_accounts[accountId].accountId != accountId) {
            revert AccountNotFound(accountId);
        }
        
        // Check that caller is the account owner
        if (_accounts[accountId].owner != msg.sender) {
            revert NotAccountOwner(msg.sender, _accounts[accountId].owner);
        }
        
        // Find and remove delegate from account
        address[] storage delegates = _accountDelegates[accountId];
        bool found = false;
        
        for (uint256 i = 0; i < delegates.length; i++) {
            if (delegates[i] == delegate) {
                // Replace with the last element and pop
                delegates[i] = delegates[delegates.length - 1];
                delegates.pop();
                found = true;
                break;
            }
        }
        
        // If delegate wasn't found, no need to continue
        if (!found) {
            return false;
        }
        
        // Remove account from delegate's accounts
        bytes32[] storage accounts = _delegateAccounts[delegate];
        
        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] == accountId) {
                // Replace with the last element and pop
                accounts[i] = accounts[accounts.length - 1];
                accounts.pop();
                break;
            }
        }
        
        emit DelegateRemoved(accountId, delegate);
        
        return true;
    }

    /**
     * @dev Get all delegates for a smart account
     * @param accountId Account ID
     * @return Array of delegate addresses
     */
    function getDelegates(bytes32 accountId) external view returns (address[] memory) {
        require(_accounts[accountId].accountId == accountId, "Account does not exist");
        return _accountDelegates[accountId];
    }

    /**
     * @dev Check if an address is a delegate for a smart account
     * @param accountId Account ID
     * @param delegate Address to check
     * @return isDelegate Whether the address is a delegate
     */
    function isDelegate(
        bytes32 accountId,
        address delegate
    ) external view returns (bool) {
        require(_accounts[accountId].accountId == accountId, "Account does not exist");
        return _isDelegateAuthorized(accountId, delegate);
    }

    /**
     * @dev Check if a delegate is authorized for an account
     * @param accountId Account ID to check
     * @param delegate Delegate address to check
     * @return True if the delegate is authorized
     */
    function _isDelegateAuthorized(bytes32 accountId, address delegate) internal view returns (bool) {
        address[] storage delegates = _accountDelegates[accountId];
        
        for (uint256 i = 0; i < delegates.length; i++) {
            if (delegates[i] == delegate) {
                return true;
            }
        }
        
        return false;
    }

    //--------------------------------------------------------------------------
    // Specialized Template Creation Functions
    //--------------------------------------------------------------------------

    /**
     * @dev Create a yield reinvestment template
     * @param name Template name
     * @param description Template description
     * @param isPublic Whether the template is public
     * @param autoCompoundFrequency Frequency of auto-compounding (in seconds)
     * @param minReinvestAmount Minimum amount to reinvest
     * @param reinvestmentTargets Target assets for reinvestment
     * @param reinvestmentAllocations Allocation percentages for reinvestment targets
     * @return templateId ID of the created template
     */
    function createYieldReinvestmentTemplate(
        string calldata name,
        string calldata description,
        bool isPublic,
        uint64 autoCompoundFrequency,
        uint256 minReinvestAmount,
        address[] calldata reinvestmentTargets,
        uint8[] calldata reinvestmentAllocations
    ) external whenNotPaused nonReentrant returns (bytes32) {
        // Validate inputs
        require(reinvestmentTargets.length > 0, "Must have at least one target");
        require(reinvestmentTargets.length == reinvestmentAllocations.length, "Target and allocation count mismatch");
        
        // Validate that allocations sum to 100%
        uint256 totalAllocation = 0;
        for (uint256 i = 0; i < reinvestmentAllocations.length; i++) {
            totalAllocation += reinvestmentAllocations[i];
        }
        require(totalAllocation == 100, "Allocations must sum to 100");
        
        // Encode the specialized parameters into the template code
        bytes memory code = abi.encode(
            "YIELD_REINVESTMENT",
            autoCompoundFrequency,
            minReinvestAmount,
            reinvestmentTargets,
            reinvestmentAllocations
        );
        
        // Create the parameter schema
        string memory parametersSchema = string(abi.encodePacked(
            '{"type":"object","properties":{"autoCompoundFrequency":{"type":"number","minimum":0},"minReinvestAmount":{"type":"string","pattern":"^[0-9]+$"},"reinvestmentTargets":{"type":"array","items":{"type":"string","pattern":"^0x[a-fA-F0-9]{40}$"}},"reinvestmentAllocations":{"type":"array","items":{"type":"number","minimum":0,"maximum":100}}},"required":["autoCompoundFrequency","minReinvestAmount","reinvestmentTargets","reinvestmentAllocations"]}'
        ));
        
        // Create the template
        return createTemplate(
            name,
            description,
            TemplateType.YIELD_REINVESTMENT,
            code,
            isPublic,
            parametersSchema,
            "1.0.0"
        );
    }

    /**
     * @dev Create an automated trading template
     * @param name Template name
     * @param description Template description
     * @param isPublic Whether the template is public
     * @param targetTokens Target tokens for trading
     * @param priceThresholds Price thresholds for trading
     * @param isPriceAbove Whether to trigger when price is above threshold
     * @param orderSizes Order sizes for each target
     * @param expirationStrategy Strategy for order expiration
     * @return templateId ID of the created template
     */
    function createAutomatedTradingTemplate(
        string calldata name,
        string calldata description,
        bool isPublic,
        address[] calldata targetTokens,
        uint256[] calldata priceThresholds,
        bool[] calldata isPriceAbove,
        uint256[] calldata orderSizes,
        uint8 expirationStrategy
    ) external whenNotPaused nonReentrant returns (bytes32) {
        // Validate inputs
        require(targetTokens.length > 0, "Must have at least one token");
        require(
            targetTokens.length == priceThresholds.length &&
            targetTokens.length == isPriceAbove.length &&
            targetTokens.length == orderSizes.length,
            "Array length mismatch"
        );
        
        // Encode the specialized parameters into the template code
        bytes memory code = abi.encode(
            "AUTOMATED_TRADING",
            targetTokens,
            priceThresholds,
            isPriceAbove,
            orderSizes,
            expirationStrategy
        );
        
        // Create the parameter schema (simplified)
        string memory parametersSchema = string(abi.encodePacked(
            '{"type":"object","properties":{"targetTokens":{"type":"array","items":{"type":"string","pattern":"^0x[a-fA-F0-9]{40}$"}},"priceThresholds":{"type":"array","items":{"type":"string","pattern":"^[0-9]+$"}},"isPriceAbove":{"type":"array","items":{"type":"boolean"}},"orderSizes":{"type":"array","items":{"type":"string","pattern":"^[0-9]+$"}},"expirationStrategy":{"type":"number","minimum":0,"maximum":255}},"required":["targetTokens","priceThresholds","isPriceAbove","orderSizes","expirationStrategy"]}'
        ));
        
        // Create the template
        return createTemplate(
            name,
            description,
            TemplateType.AUTOMATED_TRADING,
            code,
            isPublic,
            parametersSchema,
            "1.0.0"
        );
    }

    /**
     * @dev Create a portfolio rebalancing template
     * @param name Template name
     * @param description Template description
     * @param isPublic Whether the template is public
     * @param targetAssets Target assets for rebalancing
     * @param targetAllocations Target allocation percentages
     * @param rebalanceThreshold Threshold percentage to trigger rebalancing
     * @param rebalanceFrequency Frequency of rebalancing (in seconds)
     * @param maxSlippage Maximum slippage percentage allowed
     * @return templateId ID of the created template
     */
    function createPortfolioRebalancingTemplate(
        string calldata name,
        string calldata description,
        bool isPublic,
        address[] calldata targetAssets,
        uint8[] calldata targetAllocations,
        uint8 rebalanceThreshold,
        uint64 rebalanceFrequency,
        uint8 maxSlippage
    ) external whenNotPaused nonReentrant returns (bytes32) {
        // Validate inputs
        require(targetAssets.length > 0, "Must have at least one asset");
        require(targetAssets.length == targetAllocations.length, "Asset and allocation count mismatch");
        require(rebalanceThreshold > 0 && rebalanceThreshold <= 100, "Invalid rebalance threshold");
        require(maxSlippage > 0 && maxSlippage <= 100, "Invalid max slippage");
        
        // Validate that allocations sum to 100%
        uint256 totalAllocation = 0;
        for (uint256 i = 0; i < targetAllocations.length; i++) {
            totalAllocation += targetAllocations[i];
        }
        require(totalAllocation == 100, "Allocations must sum to 100");
        
        // Encode the specialized parameters into the template code
        bytes memory code = abi.encode(
            "PORTFOLIO_REBALANCING",
            targetAssets,
            targetAllocations,
            rebalanceThreshold,
            rebalanceFrequency,
            maxSlippage
        );
        
        // Create the parameter schema (simplified)
        string memory parametersSchema = string(abi.encodePacked(
            '{"type":"object","properties":{"targetAssets":{"type":"array","items":{"type":"string","pattern":"^0x[a-fA-F0-9]{40}$"}},"targetAllocations":{"type":"array","items":{"type":"number","minimum":1,"maximum":100}},"rebalanceThreshold":{"type":"number","minimum":1,"maximum":100},"rebalanceFrequency":{"type":"number","minimum":0},"maxSlippage":{"type":"number","minimum":1,"maximum":100}},"required":["targetAssets","targetAllocations","rebalanceThreshold","rebalanceFrequency","maxSlippage"]}'
        ));
        
        // Create the template
        return createTemplate(
            name,
            description,
            TemplateType.PORTFOLIO_REBALANCING,
            code,
            isPublic,
            parametersSchema,
            "1.0.0"
        );
    }

    /**
     * @dev Create a dollar cost averaging template
     * @param name Template name
     * @param description Template description
     * @param isPublic Whether the template is public
     * @param sourceAsset Source asset for investment
     * @param targetAsset Target asset for investment
     * @param investmentAmount Amount to invest each period
     * @param frequency Investment frequency (in seconds)
     * @param duration Total duration of DCA strategy (in seconds, 0 for unlimited)
     * @param maxSlippage Maximum slippage percentage allowed
     * @return templateId ID of the created template
     */
    function createDCATemplate(
        string calldata name,
        string calldata description,
        bool isPublic,
        address sourceAsset,
        address targetAsset,
        uint256 investmentAmount,
        uint64 frequency,
        uint64 duration,
        uint8 maxSlippage
    ) external whenNotPaused nonReentrant returns (bytes32) {
        // Validate inputs
        require(sourceAsset != address(0) && targetAsset != address(0), "Invalid asset addresses");
        require(sourceAsset != targetAsset, "Source and target must be different");
        require(investmentAmount > 0, "Investment amount must be positive");
        require(frequency > 0, "Frequency must be positive");
        require(maxSlippage > 0 && maxSlippage <= 100, "Invalid max slippage");
        
        // Encode the specialized parameters into the template code
        bytes memory code = abi.encode(
            "DOLLAR_COST_AVERAGING",
            sourceAsset,
            targetAsset,
            investmentAmount,
            frequency,
            duration,
            maxSlippage
        );
        
        // Create the parameter schema (simplified)
        string memory parametersSchema = string(abi.encodePacked(
            '{"type":"object","properties":{"sourceAsset":{"type":"string","pattern":"^0x[a-fA-F0-9]{40}$"},"targetAsset":{"type":"string","pattern":"^0x[a-fA-F0-9]{40}$"},"investmentAmount":{"type":"string","pattern":"^[0-9]+$"},"frequency":{"type":"number","minimum":1},"duration":{"type":"number","minimum":0},"maxSlippage":{"type":"number","minimum":1,"maximum":100}},"required":["sourceAsset","targetAsset","investmentAmount","frequency","duration","maxSlippage"]}'
        ));
        
        // Create the template
        return createTemplate(
            name,
            description,
            TemplateType.DOLLAR_COST_AVERAGING,
            code,
            isPublic,
            parametersSchema,
            "1.0.0"
        );
    }

    //--------------------------------------------------------------------------
    // Admin Functions
    //--------------------------------------------------------------------------

    /**
     * @dev Pause the contract
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
} 