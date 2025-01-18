use starknet::ContractAddress;

#[starknet::contract]
mod Vault {
    use starknet::{
        ContractAddress,
        syscalls::get_caller_address
    };

    #[storage]
    struct Storage {
        owner: ContractAddress,
        balance: u256,
        config: VaultConfig,
        options_contract: ContractAddress, // Address of the Options contract
    }

    #[derive(Drop, Serde, starknet::Store)]
    struct VaultConfig {
        option_interval: u64,
        option_size: u16,
        max_allocation: u16,
        order_timeout: u64,
        option_duration: u64
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        config: VaultConfig,
        options_contract: ContractAddress
    ) {
        self.owner.write(owner);
        self.balance.write(0.into());
        self.config.write(config);
        self.options_contract.write(options_contract);
    }

    fn deposit(ref self: ContractState, amount: u256) {
        let caller = get_caller_address();
        assert(caller == self.owner.read(), 'Only owner can deposit');
        let current_balance = self.balance.read();
        self.balance.write(current_balance + amount);
    }

    fn withdraw(ref self: ContractState, amount: u256) {
        let caller = get_caller_address();
        assert(caller == self.owner.read(), 'Only owner can withdraw');
        let current_balance = self.balance.read();
        assert(current_balance >= amount, 'Insufficient balance');
        self.balance.write(current_balance - amount);
    }

    fn execute_strategy(ref self: ContractState) {
        // Simulate strategy execution
        // Example: Create an option using the Options contract
        let option_id = self._create_option();
        // Additional logic for executing the strategy
    }

    fn _create_option(self: @ContractState) -> u256 {
        // Call the Options contract to create an option
        // Example: options_contract.create_option(strike_price, expiry, premium)
        // You need to implement this based on your Options contract's interface
        0.into() // Placeholder return value
    }
} 