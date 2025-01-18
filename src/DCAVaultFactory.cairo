use starknet::ContractAddress;

#[starknet::interface]
trait IDCAVaultFactory<TContractState> {
    fn create_vault(
        ref self: TContractState, 
        strk_token: ContractAddress,
        pragma_client: ContractAddress,
        carmine_amm: ContractAddress,
        config: VaultConfig, 
    ) -> ContractAddress;
    
    fn get_vault_count(self: @TContractState) -> u256;
    fn get_vault_by_index(self: @TContractState, index: u256) -> ContractAddress;
    fn get_vault_settings(self: @TContractState, vault: ContractAddress) -> VaultConfig;
}

#[derive(Drop, Serde, starknet::Store)]
struct VaultConfig {
    option_interval: u64,
    option_size: u16,
    max_allocation: u16,
    order_timeout: u64,
    option_duration: u64
}

#[starknet::contract]
mod DCAVaultFactory {
    use super::{VaultConfig};
    use starknet::{
        ContractAddress,
        contract_address_const,
        ClassHash,
        syscalls::deploy_syscall
    };

    #[storage]
    struct Storage {
        vault_class_hash: ClassHash,
        vault_count: u256,
        vaults: LegacyMap<u256, ContractAddress>,
        vault_configs: LegacyMap<ContractAddress, VaultConfig>,
        admin: ContractAddress
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, 
        vault_class_hash: ClassHash,
        admin: ContractAddress
    ) {
        self.vault_class_hash.write(vault_class_hash);
        self.vault_count.write(0);
        self.admin.write(admin);
    }

    #[generate_trait]
    impl PrivateFunctions of PrivateFunctionsTrait {
        fn _create_vault(
            ref self: ContractState,
            strk_token: ContractAddress,
            pragma_client: ContractAddress,
            carmine_amm: ContractAddress,
            config: VaultConfig,
        ) -> ContractAddress {
            assert(config.option_size <= 2000, 'Option size too large');
            assert(config.max_allocation <= 8000, 'Allocation too high');
            assert(config.option_interval >= 10, 'Interval too short');
            
            let (vault_address, _) = deploy_syscall(
                self.vault_class_hash.read(),
                0,
                array![
                    strk_token.into(),
                    pragma_client.into(),
                    carmine_amm.into(),
                    config.option_interval.into(),
                    config.option_size.into(),
                    config.max_allocation.into(),
                    config.order_timeout.into(),
                    config.option_duration.into()
                ].span(),
                false
            ).unwrap();

            let current_count = self.vault_count.read();
            self.vaults.write(current_count, vault_address);
            self.vault_configs.write(vault_address, config);
            self.vault_count.write(current_count + 1.into());

            emit VaultCreated {
                vault_address,
                strk_token,
                config
            };

            vault_address
        }

        fn _assert_admin(self: @ContractState) {
            let caller = starknet::get_caller_address();
            assert(caller == self.admin.read(), 'Caller is not admin');
        }
    }

    #[abi(embed_v0)]
    impl DCAVaultFactory of super::IDCAVaultFactory<ContractState> {
        fn create_vault(
            ref self: ContractState,
            strk_token: ContractAddress,
            pragma_client: ContractAddress,
            carmine_amm: ContractAddress,
            config: VaultConfig
        ) -> ContractAddress {
            self._assert_admin();
            PrivateFunctions::_create_vault(
                ref self,
                strk_token,
                pragma_client,
                carmine_amm,
                config
            )
        }

        fn get_vault_count(self: @ContractState) -> u256 {
            self.vault_count.read()
        }

        fn get_vault_by_index(self: @ContractState, index: u256) -> ContractAddress {
            assert(index < self.vault_count.read(), 'Invalid vault index');
            self.vaults.read(index)
        }

        fn get_vault_settings(self: @ContractState, vault: ContractAddress) -> VaultConfig {
            self.vault_configs.read(vault)
        }
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        VaultCreated: VaultCreated,
    }

    #[derive(Drop, starknet::Event)]
    struct VaultCreated {
        vault_address: ContractAddress,
        strk_token: ContractAddress,
        config: VaultConfig
    }
} 