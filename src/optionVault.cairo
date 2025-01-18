use starknet::ContractAddress;

#[starknet::interface]
trait IOptionVault<TContractState> {
    // User functions
    fn deposit(ref self: TContractState, amount: u256);
    fn withdraw(ref self: TContractState, shares: u256);
    fn get_user_shares(self: @TContractState, user: ContractAddress) -> u256;
    
    // Vault management
    fn create_option(ref self: TContractState) -> Result<u32, felt252>;
    fn check_option_status(ref self: TContractState, option_id: u32) -> Result<bool, felt252>;
    
    // View functions
    fn get_vault_stats(self: @TContractState) -> (u256, u256, u256, u32);
    fn get_option_details(self: @TContractState, option_id: u32) -> Option;
}

#[derive(Drop, Serde, starknet::Store)]
struct Option {
    amount: u256,
    strike_price: u256,
    creation_block: u64,
    sold_block: Option<u64>,
    premium_received: u256,
    status: OptionStatus
}

#[derive(Drop, Serde, starknet::Store)]
enum OptionStatus {
    Created: (),
    Sold: (),
    Exercised: (),
    Expired: (),
    Cancelled: ()
}

#[starknet::contract]
mod OptionVault {
    use super::{ContractAddress, Option, OptionStatus, IERC20DispatcherTrait, 
                IPragmaDispatcherTrait, ICarmineDispatcherTrait};
    use starknet::{get_caller_address, get_block_number, get_contract_address};

    #[storage]
    struct Storage {
        // Token & Integration contracts
        strk_token: IERC20Dispatcher,
        pragma_client: IPragmaDispatcher,
        carmine_amm: ICarmineDispatcher,

        // Vault parameters
        option_interval: u64,
        option_size: u16,
        max_allocation: u16,
        order_timeout: u64,
        option_duration: u64,
        last_option_block: u64,

        // Vault state
        total_shares: u256,
        total_strk: u256,
        locked_strk: u256,
        user_shares: LegacyMap<ContractAddress, u256>,
        options: LegacyMap<u32, Option>,
        option_count: u32,
        accumulated_premiums: u256
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        strk_token: ContractAddress,
        pragma_client: ContractAddress,
        carmine_amm: ContractAddress,
        option_interval: u64,
        option_size: u16,
        max_allocation: u16,
        order_timeout: u64,
        option_duration: u64
    ) {
        self.strk_token.write(IERC20Dispatcher { contract_address: strk_token });
        self.pragma_client.write(IPragmaDispatcher { contract_address: pragma_client });
        self.carmine_amm.write(ICarmineDispatcher { contract_address: carmine_amm });
        
        self.option_interval.write(option_interval);
        self.option_size.write(option_size);
        self.max_allocation.write(max_allocation);
        self.order_timeout.write(order_timeout);
        self.option_duration.write(option_duration);
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Deposit: Deposit,
        Withdraw: Withdraw,
        OptionCreated: OptionCreated,
        OptionSold: OptionSold,
        OptionExercised: OptionExercised,
        OptionExpired: OptionExpired
    }

    #[derive(Drop, starknet::Event)]
    struct Deposit {
        user: ContractAddress,
        amount: u256,
        shares: u256
    }

    #[derive(Drop, starknet::Event)]
    struct Withdraw {
        user: ContractAddress,
        shares: u256,
        amount: u256
    }

    #[derive(Drop, starknet::Event)]
    struct OptionCreated {
        option_id: u32,
        amount: u256,
        strike_price: u256
    }

    #[derive(Drop, starknet::Event)]
    struct OptionSold {
        option_id: u32,
        premium: u256
    }

    #[derive(Drop, starknet::Event)]
    struct OptionExercised {
        option_id: u32,
        profit: u256
    }

    #[derive(Drop, starknet::Event)]
    struct OptionExpired {
        option_id: u32
    }

    #[abi(embed_v0)]
    impl OptionVault of super::IOptionVault<ContractState> {
        fn deposit(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            
            // Calculate shares
            let shares = if self.total_shares.read() == 0 {
                amount
            } else {
                (amount * self.total_shares.read()) / self.total_strk.read()
            };

            // Update state
            self.total_shares.write(self.total_shares.read() + shares);
            self.total_strk.write(self.total_strk.read() + amount);
            self.user_shares.write(caller, self.user_shares.read(caller) + shares);

            // Transfer STRK tokens to vault
            self.strk_token.read().transfer_from(caller, get_contract_address(), amount);

            // Emit event
            self.emit(Deposit { user: caller, amount, shares });
        }

        fn withdraw(ref self: ContractState, shares: u256) {
            let caller = get_caller_address();
            
            // Calculate amount
            let amount = (shares * self.total_strk.read()) / self.total_shares.read();
            
            // Check available balance
            assert(amount <= self.total_strk.read() - self.locked_strk.read(), 'Insufficient available');
            assert(shares <= self.user_shares.read(caller), 'Insufficient shares');

            // Update state
            self.total_shares.write(self.total_shares.read() - shares);
            self.total_strk.write(self.total_strk.read() - amount);
            self.user_shares.write(caller, self.user_shares.read(caller) - shares);

            // Transfer STRK tokens to user
            self.strk_token.read().transfer(caller, amount);

            // Emit event
            self.emit(Withdraw { user: caller, shares, amount });
        }

        fn create_option(ref self: ContractState) -> Result<u32, felt252> {
            // Check timing
            let current_block = get_block_number();
            assert(
                current_block >= self.last_option_block.read() + self.option_interval.read(),
                'Too early'
            );

            // Check allocation
            let new_lock_amount = self.total_strk.read() * self.option_size.read().into() / 10000;
            let new_lock_ratio = (self.locked_strk.read() + new_lock_amount) * 10000 / self.total_strk.read();
            assert(new_lock_ratio <= self.max_allocation.read().into(), 'Exceeds max allocation');

            // Get price from Pragma
            let strike_price = self.pragma_client.read().get_spot_median('STRK/USD');
            
            // Create option on Carmine
            let option_id = self.carmine_amm.read().create_option(new_lock_amount, strike_price)?;

            // Store option
            self.options.write(
                option_id,
                Option {
                    amount: new_lock_amount,
                    strike_price,
                    creation_block: current_block,
                    sold_block: Option::Some(current_block + 3), // Assume sold after 3 blocks for this example
                    premium_received: 0,
                    status: OptionStatus::Created
                }
            );

            // Update state
            self.locked_strk.write(self.locked_strk.read() + new_lock_amount);
            self.last_option_block.write(current_block);
            self.option_count.write(self.option_count.read() + 1);

            // Emit event
            self.emit(OptionCreated { 
                option_id,
                amount: new_lock_amount,
                strike_price 
            });

            Result::Ok(option_id)
        }

        fn check_option_status(ref self: ContractState, option_id: u32) -> Result<bool, felt252> {
            let mut option = self.options.read(option_id);
            let current_block = get_block_number();

            // Check if option is sold (in our case, always after 3 blocks)
            if matches!(option.status, OptionStatus::Created) {
                if current_block >= option.creation_block + 3 {
                    // Option is sold, update status and record premium
                    let premium = self.carmine_amm.read().get_premium(option_id)?;
                    option.status = OptionStatus::Sold;
                    option.premium_received = premium;
                    option.sold_block = Option::Some(current_block);
                    self.options.write(option_id, option);
                    
                    // Process premium (convert to STRK and add to vault)
                    self._process_premium(premium);
                    
                    // Emit event
                    self.emit(OptionSold { option_id, premium });
                }
            }

            // Check expiration for sold options
            if matches!(option.status, OptionStatus::Sold) {
                if current_block >= option.sold_block.unwrap() + self.option_duration.read() {
                    // Get final price
                    let current_price = self.pragma_client.read().get_spot_median('STRK/USD');
                    
                    if current_price > option.strike_price {
                        // Option is exercised
                        let profit = self.carmine_amm.read().exercise_option(option_id)?;
                        option.status = OptionStatus::Exercised;
                        self.options.write(option_id, option);
                        
                        // Process exercise proceeds
                        self._process_exercise_proceeds(profit);
                        
                        // Emit event
                        self.emit(OptionExercised { option_id, profit });
                    } else {
                        // Option expires worthless
                        option.status = OptionStatus::Expired;
                        self.options.write(option_id, option);
                        
                        // Return locked tokens
                        self.locked_strk.write(self.locked_strk.read() - option.amount);
                        
                        // Emit event
                        self.emit(OptionExpired { option_id });
                    }
                    
                    return Result::Ok(false);
                }
            }

            Result::Ok(true)
        }

        fn get_user_shares(self: @ContractState, user: ContractAddress) -> u256 {
            self.user_shares.read(user)
        }

        fn get_vault_stats(self: @ContractState) -> (u256, u256, u256, u32) {
            (
                self.total_strk.read(),
                self.locked_strk.read(),
                self.accumulated_premiums.read(),
                self.option_count.read()
            )
        }

        fn get_option_details(self: @ContractState, option_id: u32) -> Option {
            self.options.read(option_id)
        }
    }

    #[generate_trait]
    impl PrivateFunctions of PrivateFunctionsTrait {
        fn _process_premium(ref self: ContractState, premium: u256) {
            // Convert premium to STRK using AMM (simplified)
            let strk_amount = premium; // In reality, would use AMM to swap
            
            // Update vault state
            self.total_strk.write(self.total_strk.read() + strk_amount);
            self.accumulated_premiums.write(self.accumulated_premiums.read() + premium);
        }

        fn _process_exercise_proceeds(ref self: ContractState, proceeds: u256) {
            // Convert exercise proceeds to STRK using AMM (simplified)
            let strk_amount = proceeds; // In reality, would use AMM to swap
            
            // Update vault state
            self.total_strk.write(self.total_strk.read() + strk_amount);
            self.locked_strk.write(self.locked_strk.read() - self.options.read(option_id).amount);
        }
    }
}