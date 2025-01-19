use starknet::ContractAddress;
 
// In order to make contract calls within our Vault,
// we need to have the interface of the remote ERC20 contract defined to import the Dispatcher.
#[starknet::interface]
pub trait IERC20<TContractState> {
    fn get_name(self: @TContractState) -> felt252;
    fn get_symbol(self: @TContractState) -> felt252;
    fn get_decimals(self: @TContractState) -> u8;
    fn get_total_supply(self: @TContractState) -> felt252;
    fn balance_of(self: @TContractState, account: ContractAddress) -> felt252;
    fn allowance(
        self: @TContractState, owner: ContractAddress, spender: ContractAddress,
    ) -> felt252;
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: felt252);
    fn transfer_from(
        ref self: TContractState,
        sender: ContractAddress,
        recipient: ContractAddress,
        amount: felt252,
    );
    fn approve(ref self: TContractState, spender: ContractAddress, amount: felt252);
    fn increase_allowance(ref self: TContractState, spender: ContractAddress, added_value: felt252);
    fn decrease_allowance(
        ref self: TContractState, spender: ContractAddress, subtracted_value: felt252,
    );
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct VaultOption {
    creator: ContractAddress,
    strike_price: u256,
    amount: u256,
    creation_block: u64,
    expiry_blocks: u64,
    exercised: bool,
    cancelled: bool
}
 
#[starknet::interface]
pub trait ISimpleVault<TContractState> {
    fn deposit(ref self: TContractState, amount: u256);
    fn withdraw(ref self: TContractState, shares: u256);
    fn user_balance_of(ref self: TContractState, account: ContractAddress) -> u256;
    fn contract_total_supply(ref self: TContractState) -> u256;

    fn create_option(ref self: TContractState, strike_price: u256, expiry_blocks: u64, amount: u256) -> u256;
    fn exercise_option(ref self: TContractState, option_id: u256, amount: u256);
    fn cancel_option(ref self: TContractState, option_id: u256);
    fn get_option_details(self: @TContractState, option_id: u256) -> VaultOption;
    fn get_next_option_id(self: @TContractState) -> u256;
    fn get_total_locked_amount(self: @TContractState) -> u256;
}
 
#[starknet::contract]
pub mod SimpleVault {
    // use super::{Option}; 
    use super::{VaultOption, IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::{ContractAddress, get_caller_address, get_contract_address,get_block_number};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    const LOCK_PERIOD: u64 = 50; // 50 blocks lock period
    const CREATION_INTERVAL: u64 = 25; // Create options every 25 blocks
    const LOCK_PERCENTAGE: u256 = 10; // 10% of tokens locked for options


    
 
    #[storage]
    struct Storage {
        token: IERC20Dispatcher,
        total_supply: u256,
        balance_of: Map<ContractAddress, u256>,
        options: Map<u256, VaultOption>,
        next_option_id: u256,
        last_creation_block: u64,
        total_locked_amount: u256
    }


 
    #[constructor]
    fn constructor(ref self: ContractState, token: ContractAddress) {
        self.token.write(IERC20Dispatcher { contract_address: token });
        self.next_option_id.write(1);
        self.last_creation_block.write(0);
        self.total_locked_amount.write(0);

    }
 
    #[generate_trait]
    impl PrivateFunctions of PrivateFunctionsTrait {
        fn _mint(ref self: ContractState, to: ContractAddress, shares: u256) {
            self.total_supply.write(self.total_supply.read() + shares);
            self.balance_of.write(to, self.balance_of.read(to) + shares);
        }
 
        fn _burn(ref self: ContractState, from: ContractAddress, shares: u256) {
            self.total_supply.write(self.total_supply.read() - shares);
            self.balance_of.write(from, self.balance_of.read(from) - shares);
        }
    }
 
    #[abi(embed_v0)]
    impl SimpleVault of super::ISimpleVault<ContractState> {
        fn user_balance_of(ref self: ContractState, account: ContractAddress) -> u256 {
            self.balance_of.read(account)
        }
 
        fn contract_total_supply(ref self: ContractState) -> u256 {
            self.total_supply.read()
        }
 
        fn deposit(ref self: ContractState, amount: u256) {
            // a = amount
            // B = balance of token before deposit
            // T = total supply
            // s = shares to mint
            //
            // (T + s) / T = (a + B) / B
            //
            // s = aT / B
            let caller = get_caller_address();
            let this = get_contract_address();
 
            let mut shares = 0;
            if self.total_supply.read() == 0 {
                shares = amount;
            } else {
                let balance: u256 = self.token.read().balance_of(this).try_into().unwrap();
                shares = (amount * self.total_supply.read()) / balance;
            }
 
            PrivateFunctions::_mint(ref self, caller, shares);
 
            let amount_felt252: felt252 = amount.low.into();
            self.token.read().transfer_from(caller, this, amount_felt252);
        }
 
        fn withdraw(ref self: ContractState, shares: u256) {
            // a = amount
            // B = balance of token before withdraw
            // T = total supply
            // s = shares to burn
            //
            // (T - s) / T = (B - a) / B
            //
            // a = sB / T
            let caller = get_caller_address();
            let this = get_contract_address();
 
            let balance = self.user_balance_of(this);
            let amount = (shares * balance) / self.total_supply.read();
            PrivateFunctions::_burn(ref self, caller, shares);
            let amount_felt252: felt252 = amount.low.into();
            self.token.read().transfer(caller, amount_felt252);
        }

        fn create_option(ref self: ContractState, strike_price: u256, expiry_blocks: u64, amount: u256) -> u256 {
            // TODO: Implement option creation logic
            // This is a placeholder return value

              // Validation checks
              assert(strike_price > 0, 'Strike price must be > 0');
              assert(amount > 0, 'Amount must be > 0');
              assert(expiry_blocks > LOCK_PERIOD, 'Expiry too short');
              let current_block = get_block_number();
              let last_creation = self.last_creation_block.read();
              assert(
                  current_block >= last_creation + CREATION_INTERVAL, 
                  'Too soon to create options'
              );
              let this = get_contract_address();
              let vault_balance: u256 = self.token.read().balance_of(this).try_into().unwrap();


              let max_lockable = (vault_balance * LOCK_PERCENTAGE) / 100;
              let current_locked = self.total_locked_amount.read();
              let current_locked_felt: u256 = max_lockable.try_into().unwrap();
              assert(current_locked + amount <=current_locked_felt, 'Exceeds lockable amount');

              let caller = get_caller_address();
              let option_id = self.next_option_id.read();
              
              let option = VaultOption {
                  creator: caller,
                  strike_price,
                  amount,
                  creation_block: current_block,
                  expiry_blocks,
                  exercised: false,
                  cancelled: false
              };
  
              self.options.write(option_id, option);
              self.next_option_id.write(option_id + 1);
              self.last_creation_block.write(current_block);
              self.total_locked_amount.write(current_locked + amount);
            return option_id;
        }

        fn exercise_option(ref self: ContractState, option_id: u256, amount: u256) {
            // TODO: Implement option exercise logic
            // This is a placeholder implementation
            // println!("Exercise option: {} {}", option_id, amount);

            let mut option = self.options.read(option_id);
            assert(!option.exercised, 'Option already exercised');
            assert(!option.cancelled, 'Option cancelled');
            
            let current_block = get_block_number();

            assert(
                current_block <= option.creation_block + option.expiry_blocks,
                'Option expired'
            );

            let caller = get_caller_address();
            assert(amount <= option.amount, 'Amount exceeds option size');


            let payment = amount * option.strike_price;
            let payment_felt: felt252 = payment.try_into().unwrap();
            let this = get_contract_address();

            self.token.read().transfer_from(caller, this, payment_felt);


                        // Update option state
                        if amount == option.amount {
                            option.exercised = true;
                            self.total_locked_amount.write(self.total_locked_amount.read() - amount);
                        } else {
                            option.amount -= amount;
                            self.total_locked_amount.write(self.total_locked_amount.read() - amount);
                        }
                        self.options.write(option_id, option);
        }

        fn cancel_option(ref self: ContractState, option_id: u256) {
            let mut option = self.options.read(option_id);
            assert(!option.exercised, 'Option already exercised');
            assert(!option.cancelled, 'Option already cancelled');

            let current_block = get_block_number();
            assert(
                current_block > option.creation_block + LOCK_PERIOD,
                'Still in lock period'
            );

            let caller = get_caller_address();
            assert(caller == option.creator, 'Only creator can cancel');

            option.cancelled = true;
            self.total_locked_amount.write(self.total_locked_amount.read() - option.amount);
            self.options.write(option_id, option);
        }

        fn get_option_details(self: @ContractState, option_id: u256) -> VaultOption {
            self.options.read(option_id)
        }

        fn get_next_option_id(self: @ContractState) -> u256 {
            self.next_option_id.read()
        }

        fn get_total_locked_amount(self: @ContractState) -> u256 {
            self.total_locked_amount.read()
        }
      

        
    }
}
 
// TODO migrate to sn-foundry
#[cfg(test)]
mod tests {
    use super::{SimpleVault, ISimpleVaultDispatcher, ISimpleVaultDispatcherTrait};
    use erc20::token::{
        IERC20DispatcherTrait as IERC20DispatcherTrait_token,
        IERC20Dispatcher as IERC20Dispatcher_token,
    };
    use starknet::testing::{set_contract_address, set_account_contract_address};
    use starknet::{ContractAddress, syscalls::deploy_syscall, contract_address_const};
 
    const token_name: felt252 = 'myToken';
    const decimals: u8 = 18;
    const initial_supply: felt252 = 100000;
    const symbols: felt252 = 'mtk';
 
    fn deploy() -> (ISimpleVaultDispatcher, ContractAddress, IERC20Dispatcher_token) {
        let _token_address: ContractAddress = contract_address_const::<'token_address'>();
        let caller = contract_address_const::<'caller'>();
 
        let (token_contract_address, _) = deploy_syscall(
            erc20::token::erc20::TEST_CLASS_HASH.try_into().unwrap(),
            caller.into(),
            array![caller.into(), token_name, decimals.into(), initial_supply, symbols].span(),
            false,
        )
            .expect('1');
 
        let (contract_address, _) = deploy_syscall(
            SimpleVault::TEST_CLASS_HASH.try_into().unwrap(),
            0,
            array![token_contract_address.into()].span(),
            false,
        )
            .expect('2');
 
        (
            ISimpleVaultDispatcher { contract_address },
            contract_address,
            IERC20Dispatcher_token { contract_address: token_contract_address },
        )
    }
 
    #[test]
    fn test_deposit() {
        let caller = contract_address_const::<'caller'>();
        let (dispatcher, vault_address, token_dispatcher) = deploy();
 
        // Approve the vault to transfer tokens on behalf of the caller
        let amount: felt252 = 10.into();
        token_dispatcher.approve(vault_address.into(), amount);
        set_contract_address(caller);
 
        // Deposit tokens into the vault
        let amount: u256 = 10.into();
        let _deposit = dispatcher.deposit(amount);
        println!("deposit :{:?}", _deposit);
 
        // Check balances and total supply
        let balance_of_caller = dispatcher.user_balance_of(caller);
        let total_supply = dispatcher.contract_total_supply();
 
        assert_eq!(balance_of_caller, amount);
        assert_eq!(total_supply, amount);
    }
 
    #[test]
    fn test_deposit_withdraw() {
        let caller = contract_address_const::<'caller'>();
        let (dispatcher, vault_address, token_dispatcher) = deploy();
 
        // Approve the vault to transfer tokens on behalf of the caller
        let amount: felt252 = 10.into();
        token_dispatcher.approve(vault_address.into(), amount);
        set_contract_address(caller);
        set_account_contract_address(vault_address);
 
        // Deposit tokens into the vault
        let amount: u256 = 10.into();
        dispatcher.deposit(amount);
        dispatcher.withdraw(amount);
 
        // Check balances of user in the vault after withdraw
        let balance_of_caller = dispatcher.user_balance_of(caller);
 
        assert_eq!(balance_of_caller, 0.into());
    }
}