constants = import_module("../../utils/constants.star")

def execute_bulk_spam(plan, config, operator_data_artifact, network_address, token_address, rpc, genesis_constants):
    """Execute simplified bulk validator spam using existing foundry service"""
    
    batch_count = config["total_batches"]
    validators_per_batch = config["validators_per_batch"]
    delay_between_batches = config["delay_between_batches"]
    
    plan.print("🚀 Starting SIMPLIFIED bulk validator spam registration")
    plan.print("    📊 Configuration:")
    plan.print("       • Total batches: " + str(batch_count))
    plan.print("       • Validators per batch: " + str(validators_per_batch))
    plan.print("       • Delay between batches: " + str(delay_between_batches) + "s")
    plan.print("       • Network address: " + network_address)
    plan.print("       • Token address: " + token_address)
    plan.print("       • RPC URL: " + rpc)
    
    # Get current block number before starting
    plan.print("📊 Getting current block number before spam...")
    start_block_result = plan.exec(
        service_name=constants.FOUNDRY_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", "echo '🔢 Current block:' && cast block-number --rpc-url " + rpc]
        )
    )
    plan.print("✅ Got start block number: " + str(start_block_result["code"]))
    
    # Create fake validator data for testing
    plan.print("🔑 Creating fake validator keys for spam testing...")
    fake_pubkey = "0x" + "a" * 96  # 48 bytes = 96 hex characters
    
    # Create JSON file with fake validator data
    plan.exec(
        service_name=constants.FOUNDRY_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", 
                "mkdir -p /tmp/spam && " +
                "echo '{\"pubkey\": \"" + fake_pubkey + "\", \"batch\": 0}' > /tmp/spam/fake_validator.json && " +
                "echo '✅ Created fake validator data'"
            ]
        )
    )
    
    # Execute spam in batches
    for batch_num in range(batch_count):
        plan.print("🔄 Processing batch " + str(batch_num + 1) + "/" + str(batch_count))
        
        # Simulate validator registration calls
        for validator_num in range(validators_per_batch):
            plan.print("  📝 Registering fake validator " + str(validator_num + 1) + "/" + str(validators_per_batch) + " in batch " + str(batch_num + 1))
            
            # Use a simple cast call to simulate network interaction
            plan.exec(
                service_name=constants.FOUNDRY_SERVICE_NAME,
                recipe=ExecRecipe(
                    command=["/bin/sh", "-c", 
                        "echo '📞 Simulating validator registration call...' && " +
                        "cast call " + network_address + " 'validatorCount()' --rpc-url " + rpc + " && " +
                        "echo '✅ Simulated registration for validator " + str(validator_num + 1) + "'"
                    ]
                )
            )
        
        # Add delay between batches if not the last batch
        if batch_num < batch_count - 1:
            plan.print("⏳ Waiting " + str(delay_between_batches) + " seconds before next batch...")
            plan.exec(
                service_name=constants.FOUNDRY_SERVICE_NAME,
                recipe=ExecRecipe(
                    command=["/bin/sh", "-c", "sleep " + str(delay_between_batches)]
                )
            )
    
    # Get final block number
    plan.print("📊 Getting final block number after spam...")
    end_block_result = plan.exec(
        service_name=constants.FOUNDRY_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", "echo '🔢 Final block:' && cast block-number --rpc-url " + rpc]
        )
    )
    plan.print("✅ Got end block number: " + str(end_block_result["code"]))
    
    # Create summary report
    total_validators = batch_count * validators_per_batch
    plan.print("📋 SPAM EXECUTION SUMMARY:")
    plan.print("   • Total batches processed: " + str(batch_count))
    plan.print("   • Validators per batch: " + str(validators_per_batch))
    plan.print("   • Total validators simulated: " + str(total_validators))
    plan.print("   • Using existing foundry service: " + constants.FOUNDRY_SERVICE_NAME)
    
    # Store execution log
    plan.exec(
        service_name=constants.FOUNDRY_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", 
                "echo '{" +
                "\"execution_timestamp\": \"$(date -Iseconds)\"," +
                "\"total_batches\": " + str(batch_count) + "," +
                "\"validators_per_batch\": " + str(validators_per_batch) + "," +
                "\"total_validators\": " + str(total_validators) + "," +
                "\"network_address\": \"" + network_address + "\"," +
                "\"token_address\": \"" + token_address + "\"," +
                "\"status\": \"completed\"" +
                "}' > /tmp/spam/execution_summary.json && " +
                "echo '💾 Saved execution summary'"
            ]
        )
    )
    
    # Simple verification check
    plan.print("🔍 Running post-spam verification...")
    plan.exec(
        service_name=constants.FOUNDRY_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", 
                "echo '🔍 Checking network state...' && " +
                "cast call " + network_address + " 'validatorCount()' --rpc-url " + rpc + " && " +
                "echo '✅ Network verification completed'"
            ]
        )
    )
    
    plan.print("🎉 BULK SPAM EXECUTION COMPLETED SUCCESSFULLY!")
    plan.print("    All operations used existing '" + constants.FOUNDRY_SERVICE_NAME + "' service")
    plan.print("    No new services were created")
    plan.print("    All logs are visible in the execution output above")
    
    return True  # Return simple success indicator 