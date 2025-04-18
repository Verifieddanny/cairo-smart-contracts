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
 
#[starknet::interface]
pub trait ISimpleVault<TContractState> {
    fn deposit(ref self: TContractState, amount: u256);
    fn withdraw(ref self: TContractState, shares: u256);
    fn user_balance_of(self: @TContractState, account: ContractAddress) -> u256;
    fn contract_total_supply(self: @TContractState) -> u256;
}
 
#[starknet::contract]
pub mod SimpleVault {
    use super::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
 
    #[storage]
    struct Storage {
        token: IERC20Dispatcher,
        total_supply: u256,
        balance_of: Map<ContractAddress, u256>,
    }
 
    #[constructor]
    fn constructor(ref self: ContractState, token: ContractAddress) {
        self.token.write(IERC20Dispatcher { contract_address: token });
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
        fn user_balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.balance_of.read(account)
        }
 
        fn contract_total_supply(self: @ContractState) -> u256 {
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
    }
}
 
#[cfg(test)]
mod tests {
    use super::{ISimpleVaultDispatcher, ISimpleVaultDispatcherTrait};
    use erc20::token::{
        IERC20DispatcherTrait as IERC20DispatcherTrait_token,
        IERC20Dispatcher as IERC20Dispatcher_token,
    };
    use starknet::{ContractAddress, contract_address_const};
 
    const token_name: felt252 = 'myToken';
    const decimals: u8 = 18;
    const initial_supply: felt252 = 100000;
    const symbols: felt252 = 'mtk';
 
    use snforge_std::{
        ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address_global,
    };
 
    fn deploy() -> (ISimpleVaultDispatcher, IERC20Dispatcher_token) {
        let _token_address: ContractAddress = contract_address_const::<'token_address'>();
        let caller = contract_address_const::<'caller'>();
 
        let token_contract = declare("erc20").unwrap().contract_class();
        let (token_contract_address, _) = token_contract
            .deploy(@array![caller.into(), token_name, decimals.into(), initial_supply, symbols])
            .unwrap();
 
        let vault_contract = declare("SimpleVault").unwrap().contract_class();
        let (vault_contract_address, _) = vault_contract
            .deploy(@array![token_contract_address.into()])
            .unwrap();
 
        (
            ISimpleVaultDispatcher { contract_address: vault_contract_address },
            IERC20Dispatcher_token { contract_address: token_contract_address },
        )
    }
 
    #[test]
    fn test_deposit() {
        let caller = contract_address_const::<'caller'>();
        let (vault, token) = deploy();
 
        // Approve the vault to transfer tokens on behalf of the caller
        let amount: felt252 = 10.into();
        token.approve(vault.contract_address.into(), amount);
        start_cheat_caller_address_global(caller);
 
        // Deposit tokens into the vault
        let amount: u256 = 10.into();
        let _deposit = vault.deposit(amount);
        println!("deposit :{:?}", _deposit);
 
        // Check balances and total supply
        let balance_of_caller = vault.user_balance_of(caller);
        let total_supply = vault.contract_total_supply();
 
        assert_eq!(balance_of_caller, amount);
        assert_eq!(total_supply, amount);
    }
 
    #[test]
    fn test_deposit_withdraw() {
        let caller = contract_address_const::<'caller'>();
        let (vault, token) = deploy();
 
        // Approve the vault to transfer tokens on behalf of the caller
        let amount: felt252 = 10.into();
        token.approve(vault.contract_address.into(), amount);
 
        start_cheat_caller_address_global(caller);
 
        // Deposit tokens into the vault
        let amount: u256 = 10.into();
        vault.deposit(amount);
        vault.withdraw(amount);
 
        // Check balances of user in the vault after withdraw
        let balance_of_caller = vault.user_balance_of(caller);
 
        assert_eq!(balance_of_caller, 0.into());
    }
}