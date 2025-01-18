use starknet::ContractAddress;

#[starknet::contract]
mod Options {
    use starknet::{
        ContractAddress,
        syscalls::{get_caller_address, get_block_number}
    };

    #[storage]
    struct Storage {
        options: LegacyMap<u256, OptionData>,
        next_option_id: u256,
        token_contract: ContractAddress, // Address of the token contract
    }

    #[derive(Drop, Serde, starknet::Store)]
    struct OptionData {
        owner: ContractAddress,
        strike_price: u256,
        expiry: u256,
        is_exercised: bool,
    }

    #[constructor]
    fn constructor(ref self: ContractState, token_contract: ContractAddress) {
        self.next_option_id.write(0.into());
        self.token_contract.write(token_contract);
    }

    fn create_option(
        ref self: ContractState,
        strike_price: u256,
        expiry: u256,
        premium: u256
    ) -> u256 {
        let caller = get_caller_address();
        let option_id = self.next_option_id.read();

        let option_data = OptionData {
            owner: caller,
            strike_price,
            expiry,
            is_exercised: false,
        };

        self.options.write(option_id, option_data);
        self.next_option_id.write(option_id + 1.into());

        // Transfer premium from caller to contract
        self._transfer_tokens(caller, self.token_contract.read(), premium);

        option_id
    }

    fn exercise_option(ref self: ContractState, option_id: u256) {
        let caller = get_caller_address();
        let mut option_data = self.options.read(option_id);

        assert(option_data.owner == caller, 'Only owner can exercise');
        assert(!option_data.is_exercised, 'Option already exercised');
        assert(option_data.expiry > get_block_number(), 'Option expired');

        option_data.is_exercised = true;
        self.options.write(option_id, option_data);

        // Mint tokens to the caller as a payout
        self._mint_tokens(caller, 100.into()); // Example payout amount
    }

    fn expire_option(ref self: ContractState, option_id: u256) {
        let mut option_data = self.options.read(option_id);

        assert(option_data.expiry <= get_block_number(), 'Option not expired');
        assert(!option_data.is_exercised, 'Option already exercised');

        // Logic to handle the expiration of the option
        // For example, mark it as expired or remove it from storage
    }

    fn get_option_data(self: @ContractState, option_id: u256) -> OptionData {
        self.options.read(option_id)
    }

    // Helper function to transfer tokens
    fn _transfer_tokens(self: @ContractState, from: ContractAddress, to: ContractAddress, amount: u256) {
        // Call the token contract's transfer function
        // Example: token_contract.transfer(from, to, amount)
        // You need to implement this based on your token contract's interface
    }

    // Helper function to mint tokens
    fn _mint_tokens(self: @ContractState, to: ContractAddress, amount: u256) {
        // Call the token contract's mint function
        // Example: token_contract.mint(to, amount)
        // You need to implement this based on your token contract's interface
    }
} 