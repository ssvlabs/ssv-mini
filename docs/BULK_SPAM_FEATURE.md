# Bulk Validator Spam Feature

This feature allows you to spam the SSV network with bulk validator registration events using randomly generated fake validator keys. This is useful for load testing, stress testing, and analyzing network performance under high validator registration loads.

## Overview

The bulk spam feature generates fake BLS public keys and registers them as validators on the SSV network without requiring actual ETH deposits. The feature provides detailed logging and statistics about registration performance, including events per block metrics, and includes comprehensive verification to ensure events are properly processed.

## Configuration

Add the following configuration to your `params.yaml` file under the `custom` section:

```yaml
custom:
  bulk_validator_spam:
    enabled: true                    # Set to true to enable spam registration
    validators_per_batch: 20         # Number of fake validators to register per batch
    total_batches: 5                 # Total number of spam batches to execute
    delay_between_batches: 24        # Wait time between batches (seconds)
    target_events_per_block: 5       # Target validator registration events per block
    detailed_logging: true           # Enable detailed logging and statistics
    # Verification settings
    verification:
      enabled: true                  # Enable post-spam verification
      check_contract_events: true    # Verify events in SSV contract via ETH API
      check_ssv_node_logs: true      # Verify SSV nodes processed the events
      verification_timeout: 300      # Timeout for verification checks (seconds)
      blocks_to_check: 10            # Number of recent blocks to analyze for events
```

### Configuration Parameters

- **`enabled`**: Boolean flag to enable/disable the bulk spam feature
- **`validators_per_batch`**: Number of fake validators to register in each batch
- **`total_batches`**: Total number of batches to execute
- **`delay_between_batches`**: Time to wait between batches in seconds (useful for controlling load)
- **`target_events_per_block`**: Target number of validator registration events per blockchain block
- **`detailed_logging`**: Enable detailed logging and statistics collection

### Verification Parameters

- **`verification.enabled`**: Enable/disable post-spam verification
- **`verification.check_contract_events`**: Verify events in SSV contract via Ethereum JSON-RPC API
- **`verification.check_ssv_node_logs`**: Verify SSV nodes processed the events by analyzing their logs
- **`verification.verification_timeout`**: Timeout for verification operations (seconds)
- **`verification.blocks_to_check`**: Number of recent blocks to analyze for events

## How It Works

1. **Key Generation**: Generates deterministic fake BLS public keys using SHA256 hashing
2. **Batch Processing**: Processes validators in configurable batches
3. **Smart Contract Interaction**: Uses a custom Solidity contract to register fake validators
4. **Performance Monitoring**: Tracks registration performance and events per block
5. **Event Verification**: Verifies events are properly recorded in the blockchain
6. **Node Log Verification**: Confirms SSV nodes processed the events correctly
7. **Detailed Logging**: Stores comprehensive logs and statistics

## Generated Files and Logs

The feature generates several files for monitoring and analysis:

### Log Files Location
All logs are stored in service containers and are available as Kurtosis artifacts:
- **`bulk-spam-logs`**: Spam execution logs and statistics
- **`verification-logs`**: Verification results and analysis

### Generated Files

#### Spam Execution Files
1. **`spam_session.json`**: Complete session statistics including:
   - Session start/end times and blocks
   - Configuration parameters
   - Per-batch detailed statistics
   - Overall summary metrics

2. **`batch_N_output.log`**: Individual forge script outputs for each batch

3. **`fake-keys/batch_N.json`**: Generated fake validator keys for each batch

4. **`fake-keys/summary.json`**: Summary of all generated keys

#### Verification Files
1. **`master_verification.json`**: Complete verification summary including:
   - Overall verification success/failure
   - Individual verification component results
   - Configuration and timing information

2. **`contract_events_verification.json`**: Contract events analysis including:
   - Events found per block
   - Success rate vs expected events
   - Block-by-block event breakdown

3. **`ssv_node_logs_verification.json`**: SSV node logs analysis including:
   - Per-node activity analysis
   - Event processing verification
   - Error detection and reporting

### Example Verification Log Structure

```json
{
  "verification_start": "2024-01-15T10:35:00Z",
  "configuration": {
    "ssv_contract_address": "0x123...",
    "block_range": {"start": 150, "end": 160},
    "expected_events": 100,
    "check_contract_events": true,
    "check_ssv_node_logs": true
  },
  "verification_results": {
    "contract_events": {
      "status": "passed",
      "actual_events": 100,
      "success_rate_percent": 100
    },
    "ssv_node_logs": {
      "status": "passed",
      "total_ssv_nodes": 4,
      "active_nodes": 4,
      "active_percentage": 100
    }
  },
  "overall_success": true
}
```

## Verification Process

The verification system provides two-layer validation:

### 1. Contract Events Verification
- **Method**: Queries Ethereum JSON-RPC API using `eth_getLogs`
- **Target**: SSV contract `ValidatorAdded` events
- **Analysis**: 
  - Counts events in the specified block range
  - Groups events by block number
  - Calculates success rate vs expected events
  - Identifies discrepancies and missing events

### 2. SSV Node Logs Verification
- **Method**: Analyzes SSV node service logs via Kurtosis
- **Target**: SSV node event processing logs
- **Analysis**:
  - Searches for validator registration patterns
  - Checks block processing activity
  - Detects errors and failures
  - Measures node activity and responsiveness

### Verification Success Criteria
- **Full Success**: All expected events found + all SSV nodes active + no errors
- **Partial Success**: Some events found + some nodes active + minimal errors
- **Failure**: Missing events or inactive nodes or significant errors

## Security Considerations

⚠️ **Important Security Notes:**

1. **Fake Keys Only**: The generated keys are NOT real BLS keys and cannot be used for actual validation
2. **No ETH Deposits**: Validators are registered with minimal deposits for testing purposes only
3. **Test Networks Only**: This feature should only be used on test networks, never on mainnet
4. **Resource Usage**: Large batch sizes may consume significant gas and network resources
5. **Verification Impact**: Log analysis may affect performance on systems with limited resources

## Usage Example

1. Copy the example configuration:
   ```bash
   cp params-spam-example.yaml params.yaml
   ```

2. Modify the spam and verification configuration as needed

3. Run the SSV network:
   ```bash
   kurtosis run .
   ```

4. Monitor the spam execution and verification in the Kurtosis logs

5. Extract logs for analysis:
   ```bash
   # Spam execution logs
   kurtosis service logs bulk-validator-spam
   
   # Verification logs
   kurtosis service logs bulk-validator-spam-verification
   ```

6. Download artifacts for detailed analysis:
   ```bash
   kurtosis files download bulk-spam-logs ./spam-logs/
   kurtosis files download verification-logs ./verification-logs/
   ```

## Performance Metrics

The feature tracks several key performance metrics:

### Spam Execution Metrics
- **Total Validators Registered**: Total number of fake validators successfully registered
- **Events Per Block**: Average and per-batch validator registration events per blockchain block
- **Batch Success Rate**: Percentage of batches that completed successfully
- **Processing Time**: Time taken for each batch and overall session
- **Block Usage**: Number of blockchain blocks used for registration

### Verification Metrics
- **Event Verification Rate**: Percentage of expected events found in contract logs
- **Node Activity Rate**: Percentage of SSV nodes actively processing events
- **Verification Success**: Overall verification pass/fail status
- **Error Detection**: Number and types of errors found during verification

## Troubleshooting

### Common Issues

#### Spam Execution Issues
1. **Batch Failures**: Check individual batch logs in `batch_N_output.log` files
2. **High Gas Usage**: Reduce `validators_per_batch` or `target_events_per_block`
3. **Network Congestion**: Increase `delay_between_batches`
4. **Contract Errors**: Ensure SSV contracts are properly deployed

#### Verification Issues
1. **Contract Events Not Found**: 
   - Check if spam registration actually succeeded
   - Verify SSV contract address is correct
   - Ensure RPC endpoint is responding correctly

2. **SSV Node Logs Empty**:
   - Verify SSV nodes are running and healthy
   - Check if nodes have proper logging configuration
   - Ensure sufficient time has passed for log generation

3. **Verification Timeout**:
   - Increase `verification_timeout` value
   - Reduce `blocks_to_check` range
   - Check network connectivity

### Debug Mode

Enable detailed logging by setting `detailed_logging: true` in the configuration. This provides:
- Preview of generated public keys
- Detailed error messages
- Extended batch statistics
- Step-by-step execution logs
- Verbose verification output

### Verification Debug

Enable verification debugging by:
1. Setting `verification.enabled: true`
2. Checking individual verification log files
3. Analyzing the `master_verification.json` for overall status
4. Examining per-node analysis in SSV logs verification

## Architecture

The bulk spam feature consists of several components:

### Core Components
1. **`generators/bulk-spam.star`**: Main orchestration logic
2. **`contract/registration/BulkSpamRegistration.s.sol`**: Solidity contract for batch registration
3. **`tests/bulk-spam/scripts/generate-fake-keys.sh`**: Fake key generation script
4. **`tests/bulk-spam/scripts/bulk-spam-registration.sh`**: Main execution script

### Verification Components
1. **`tests/bulk-spam/scripts/verify-contract-events.sh`**: Contract events verification via Ethereum API
2. **`tests/bulk-spam/scripts/verify-ssv-node-logs.sh`**: SSV node logs analysis
3. **`tests/bulk-spam/scripts/master-verification.sh`**: Verification coordinator

This modular design allows for easy customization and extension of both the spam testing and verification capabilities. 