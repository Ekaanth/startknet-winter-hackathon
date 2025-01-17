use starknet::ContractAddress;

#[starknet::interface]
trait ISimpleVaultFactory<TContractState> {
    fn create_vault(ref self: TContractState, token: ContractAddress) -> ContractAddress;
    fn get_vault_count(self: @TContractState) -> u256;
    fn get_vault_by_index(self: @TContractState, index: u256) -> ContractAddress;
    fn get_vault_by_token(self: @TContractState, token: ContractAddress) -> ContractAddress;
}

#[starknet::contract]
mod SimpleVaultFactory {
    use starknet::{
        ContractAddress,
        contract_address_const,
        ClassHash,
        syscalls::deploy_syscall,
    };
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };

    #[storage]
    struct Storage {
        vault_class_hash: ClassHash,
        vault_count: u256,
        vaults: Map<u256, ContractAddress>,
        token_to_vault: Map<ContractAddress, ContractAddress>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, vault_class_hash: ClassHash) {
        self.vault_class_hash.write(vault_class_hash);
        self.vault_count.write(0);
    }

    #[generate_trait]
    impl PrivateFunctions of PrivateFunctionsTrait {
        fn _create_vault(
            ref self: ContractState,
            token: ContractAddress,
        ) -> ContractAddress {
            // Deploy new vault
            let (vault_address, _) = deploy_syscall(
                self.vault_class_hash.read(),
                0,
                array![token.into()].span(),
                false
            ).unwrap();

            // Update storage
            let current_count = self.vault_count.read();
            self.vaults.write(current_count, vault_address);
            self.token_to_vault.write(token, vault_address);
            self.vault_count.write(current_count + 1.into());

            vault_address
        }
    }

    #[abi(embed_v0)]
    impl SimpleVaultFactory of super::ISimpleVaultFactory<ContractState> {
        fn create_vault(ref self: ContractState, token: ContractAddress) -> ContractAddress {
            // Check if vault already exists for this token
            let existing_vault = self.token_to_vault.read(token);
            if existing_vault != contract_address_const::<0>() {
                return existing_vault;
            }

            // Create new vault
            PrivateFunctions::_create_vault(ref self, token)
        }

        fn get_vault_count(self: @ContractState) -> u256 {
            self.vault_count.read()
        }

        fn get_vault_by_index(self: @ContractState, index: u256) -> ContractAddress {
            assert(index < self.vault_count.read(), 'Invalid vault index');
            self.vaults.read(index)
        }

        fn get_vault_by_token(self: @ContractState, token: ContractAddress) -> ContractAddress {
            self.token_to_vault.read(token)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::SimpleVaultFactory;
    use starknet::{
        ContractAddress, 
        contract_address_const,
        ClassHash,
        syscalls::deploy_syscall
    };
    use starknet::testing::set_contract_address;

    // Mock class hash for testing
    const MOCK_CLASS_HASH: felt252 = 123456;

    #[test]
    fn test_create_vault() {
        let caller = contract_address_const::<'caller'>();
        set_contract_address(caller);

        // Deploy factory with mock vault class hash
        let (factory_address, _) = deploy_syscall(
            SimpleVaultFactory::TEST_CLASS_HASH.try_into().unwrap(),
            0,
            array![MOCK_CLASS_HASH].span(),
            false
        ).unwrap();

        // Create dispatcher
        let dispatcher = ISimpleVaultFactoryDispatcher { contract_address: factory_address };
        
        let token_address = contract_address_const::<'token'>();

        // Create vault
        let vault_address = dispatcher.create_vault(token_address);
        assert(vault_address != contract_address_const::<0>(), 'Invalid vault address');

        // Verify vault count and mapping
        assert(dispatcher.get_vault_count() == 1.into(), 'Invalid vault count');
        assert(
            dispatcher.get_vault_by_token(token_address) == vault_address,
            'Invalid vault mapping'
        );
        assert(
            dispatcher.get_vault_by_index(0.into()) == vault_address,
            'Invalid vault index'
        );
    }

    #[test]
    fn test_duplicate_vault() {
        let caller = contract_address_const::<'caller'>();
        set_contract_address(caller);

        // Deploy factory with mock vault class hash
        let (factory_address, _) = deploy_syscall(
            SimpleVaultFactory::TEST_CLASS_HASH.try_into().unwrap(),
            0,
            array![MOCK_CLASS_HASH].span(),
            false
        ).unwrap();

        // Create dispatcher
        let dispatcher = ISimpleVaultFactoryDispatcher { contract_address: factory_address };
        
        let token_address = contract_address_const::<'token'>();

        // Create first vault
        let vault_address1 = dispatcher.create_vault(token_address);
        
        // Try to create duplicate vault
        let vault_address2 = dispatcher.create_vault(token_address);

        // Verify same vault is returned
        assert(vault_address1 == vault_address2, 'Different vault returned');
        assert(dispatcher.get_vault_count() == 1.into(), 'Invalid vault count');
    }
}