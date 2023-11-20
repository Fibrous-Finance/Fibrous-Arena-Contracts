use core::array::ArrayTrait;
use starknet::ContractAddress;
use starknet::ClassHash;


#[starknet::interface]
trait IERC721<TContractState> {
    fn name(self: @TContractState) -> felt252;
    fn symbol(self: @TContractState) -> felt252;
    fn tokenUri(self: @TContractState, token_id: u256) -> Array<felt252>;
    fn balanceOf(self: @TContractState, account: ContractAddress) -> u256;
    fn isApprovedForAll(
        self: @TContractState, owner: ContractAddress, operator: ContractAddress
    ) -> bool;
    fn totalSupply(self: @TContractState) -> u256;
    fn ownerOf(self: @TContractState, token_id: u256) -> ContractAddress;
    fn getApproved(self: @TContractState, token_id: u256) -> ContractAddress;
    fn baseUri(self: @TContractState) -> Array<felt252>;
    fn owner(self: @TContractState) -> ContractAddress;

    fn setApprovalForAll(ref self: TContractState, operator: ContractAddress, approved: bool);
    fn approve(ref self: TContractState, to: ContractAddress, token_id: u256);
    fn transferFrom(
        ref self: TContractState, from: ContractAddress, to: ContractAddress, token_id: u256
    );
    fn mint(ref self: TContractState, addresses: Array<ContractAddress>);

    fn setTokenUri(ref self: TContractState, uri: Array<felt252>);
    fn transferOwnership(ref self: TContractState, new_owner: ContractAddress);
    fn burn(ref self: TContractState, token_id: u256);
    fn upgrade(ref self: TContractState, new_implementation: ClassHash);
}

#[starknet::contract]
mod ERC721 {
    use starknet::{
        get_caller_address, ContractAddress, contract_address_const,
        contract_address_try_from_felt252, ClassHash
    };
    use traits::Into;
    use array::{Array, ArrayTrait};
    use zeroable::Zeroable;
    use traits::TryInto;
    use option::OptionTrait;
    use integer::{u32_try_from_felt252};
    use starknet::syscalls::replace_class_syscall;


    #[storage]
    struct Storage {
        name: felt252,
        symbol: felt252,
        owners: LegacyMap::<u256, ContractAddress>,
        balances: LegacyMap::<ContractAddress, u256>,
        token_approvals: LegacyMap::<u256, ContractAddress>,
        operator_approvals: LegacyMap::<(ContractAddress, ContractAddress), bool>,
        contract_owner: ContractAddress,
        base_uri: LegacyMap<u32, felt252>,
        base_uri_len: u32,
        uri_extension: felt252,
        total_supply: u256,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Approval: Approval,
        Transfer: Transfer,
        ApprovalForAll: ApprovalForAll,
    }
    #[derive(Drop, starknet::Event)]
    struct Approval {
        owner: ContractAddress,
        to: ContractAddress,
        token_id: u256
    }
    #[derive(Drop, starknet::Event)]
    struct Transfer {
        from: ContractAddress,
        to: ContractAddress,
        token_id: u256
    }
    #[derive(Drop, starknet::Event)]
    struct ApprovalForAll {
        owner: ContractAddress,
        operator: ContractAddress,
        approved: bool
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        _name: felt252,
        _symbol: felt252,
        owner: ContractAddress,
        uri_extension: felt252
    ) {
        self.name.write(_name);
        self.symbol.write(_symbol);
        self.contract_owner.write(owner);
        self.uri_extension.write(uri_extension);
    }

    #[external(v0)]
    impl IERC721Impl of super::IERC721<ContractState> {
        fn name(self: @ContractState) -> felt252 {
            self.name.read()
        }

        fn symbol(self: @ContractState) -> felt252 {
            self.symbol.read()
        }

        fn balanceOf(self: @ContractState, account: ContractAddress) -> u256 {
            assert(!account.is_zero(), 'ERC721: address zero');
            self.balances.read(account)
        }

        fn totalSupply(self: @ContractState) -> u256 {
            self.total_supply.read()
        }

        fn isApprovedForAll(
            self: @ContractState, owner: ContractAddress, operator: ContractAddress
        ) -> bool {
            self._is_approved_for_all(owner, operator)
        }

        fn tokenUri(self: @ContractState, token_id: u256) -> Array<felt252> {
            self._require_minted(token_id);
            let mut uri = self._token_uri();
            uri.append(token_id.try_into().unwrap());
            uri.append(self.uri_extension.read());
            uri
        }

        fn ownerOf(self: @ContractState, token_id: u256) -> ContractAddress {
            let owner = self._owner_of(token_id);
            assert(!owner.is_zero(), 'ERC721: invalid token ID');
            owner
        }

        fn getApproved(self: @ContractState, token_id: u256) -> ContractAddress {
            self._get_approved(token_id)
        }

        fn baseUri(self: @ContractState) -> Array<felt252> {
            self._token_uri()
        }

        fn owner(self: @ContractState) -> ContractAddress {
            self.contract_owner.read()
        }

        fn transferFrom(
            ref self: ContractState, from: ContractAddress, to: ContractAddress, token_id: u256
        ) {
            assert(
                self._is_approved_or_owner(get_caller_address(), token_id),
                'Caller is not owner or appvored'
            );
            self._transfer(from, to, token_id);
        }

        fn setApprovalForAll(
            ref self: ContractState, operator: ContractAddress, approved: bool
        ) {
            self._set_approval_for_all(get_caller_address(), operator, approved);
        }

        fn approve(ref self: ContractState, to: ContractAddress, token_id: u256) {
            let owner = self._owner_of(token_id);
            // Unlike Solidity, require is not supported, only assert can be used
            // The max length of error msg is 31 or there's an error
            assert(to != owner, 'Approval to current owner');
            // || is not supported currently so we use | here
            assert(
                (get_caller_address() == owner)
                    | self._is_approved_for_all(owner, get_caller_address()),
                'Not token owner'
            );
            self._approve(to, token_id);
        }

        fn mint(ref self: ContractState, addresses: Array<ContractAddress>) {
            let caller = get_caller_address();
            assert(!caller.is_zero(), 'ERC721: mint to 0');
            assert(caller == self.contract_owner.read(), 'UNAUTHORIZED_OWNER');
            let mut index = 0_u32;
            loop {
                if (addresses.len() == index) {
                    break ();
                }
                let token_id = self.total_supply.read() + 1.into();
                self._mint(*addresses[index], token_id);
                self.total_supply.write(token_id);
                index += 1;
            };
        }

        fn setTokenUri(ref self: ContractState, uri: Array<felt252>) {
            self._set_token_uri(uri);
        }

        fn transferOwnership(ref self: ContractState, new_owner: ContractAddress) {
            assert(get_caller_address() == self.contract_owner.read(), 'UNAUTHORIZED_OWNER');
            self.contract_owner.write(new_owner);
        }

        fn burn(ref self: ContractState, token_id: u256) {
            assert(get_caller_address() == self._owner_of(token_id), 'UNAUTHORIZED_OWNER');
            self._burn(token_id);
        }

        fn upgrade(ref self: ContractState, new_implementation: ClassHash) {
            assert(get_caller_address() == self.contract_owner.read(), 'UNAUTHORIZED_OWNER');
            replace_class_syscall(new_implementation);
        }
    }

    #[generate_trait]
    impl StorageImpl of StorageTrait {
        fn _set_approval_for_all(
            ref self: ContractState,
            owner: ContractAddress,
            operator: ContractAddress,
            approved: bool
        ) {
            assert(owner != operator, 'ERC721: approve to caller');
            self.operator_approvals.write((owner, operator), approved);
            self.emit(Event::ApprovalForAll(ApprovalForAll { owner, operator, approved }));
        }

        fn _approve(ref self: ContractState, to: ContractAddress, token_id: u256) {
            self.token_approvals.write(token_id, to);
            self.emit(Event::Approval(Approval { owner: self._owner_of(token_id), to, token_id }));
        }

        fn _is_approved_for_all(
            self: @ContractState, owner: ContractAddress, operator: ContractAddress
        ) -> bool {
            self.operator_approvals.read((owner, operator))
        }

        fn _owner_of(self: @ContractState, token_id: u256) -> ContractAddress {
            self.owners.read(token_id)
        }

        fn _exists(self: @ContractState, token_id: u256) -> bool {
            !self._owner_of(token_id).is_zero()
        }

        fn _get_approved(self: @ContractState, token_id: u256) -> ContractAddress {
            self._require_minted(token_id);
            self.token_approvals.read(token_id)
        }

        fn _require_minted(self: @ContractState, token_id: u256) {
            assert(self._exists(token_id), 'ERC721: invalid token ID');
        }

        fn _is_approved_or_owner(
            self: @ContractState, spender: ContractAddress, token_id: u256
        ) -> bool {
            let owner = self.owners.read(token_id);
            // || is not supported currently so we use | here
            (spender == owner)
                | self._is_approved_for_all(owner, spender)
                | (self._get_approved(token_id) == spender)
        }

        fn _transfer(
            ref self: ContractState, from: ContractAddress, to: ContractAddress, token_id: u256
        ) {
            assert(from == self._owner_of(token_id), 'Transfer from incorrect owner');
            assert(!to.is_zero(), 'ERC721: transfer to 0');

            self._beforeTokenTransfer(from, to, token_id, 1.into());
            assert(from == self._owner_of(token_id), 'Transfer from incorrect owner');

            self.token_approvals.write(token_id, contract_address_const::<0>());

            self.balances.write(from, self.balances.read(from) - 1.into());
            self.balances.write(to, self.balances.read(to) + 1.into());

            self.owners.write(token_id, to);

            self.emit(Event::Transfer(Transfer { from, to, token_id }));

            self._afterTokenTransfer(from, to, token_id, 1.into());
        }

        fn _mint(ref self: ContractState, to: ContractAddress, token_id: u256) {
            assert(!to.is_zero(), 'ERC721: mint to 0');
            assert(!self._exists(token_id), 'ERC721: already minted');
            self._beforeTokenTransfer(contract_address_const::<0>(), to, token_id, 1.into());
            assert(!self._exists(token_id), 'ERC721: already minted');

            self.balances.write(to, self.balances.read(to) + 1.into());
            self.owners.write(token_id, to);
            // contract_address_const::<0>() => means 0 address
            self
                .emit(
                    Event::Transfer(Transfer { from: contract_address_const::<0>(), to, token_id })
                );

            self._afterTokenTransfer(contract_address_const::<0>(), to, token_id, 1.into());
        }


        fn _burn(ref self: ContractState, token_id: u256) {
            let owner = self._owner_of(token_id);
            self._beforeTokenTransfer(owner, contract_address_const::<0>(), token_id, 1.into());
            let owner = self._owner_of(token_id);
            self.token_approvals.write(token_id, contract_address_const::<0>());

            self.balances.write(owner, self.balances.read(owner) - 1.into());
            self.owners.write(token_id, contract_address_const::<0>());
            self
                .emit(
                    Event::Transfer(
                        Transfer { from: owner, to: contract_address_const::<0>(), token_id }
                    )
                );

            self._afterTokenTransfer(owner, contract_address_const::<0>(), token_id, 1.into());
        }

        fn _beforeTokenTransfer(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            first_token_id: u256,
            batch_size: u256
        ) {}

        fn _afterTokenTransfer(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            first_token_id: u256,
            batch_size: u256
        ) {}

        fn _token_uri(self: @ContractState) -> Array<felt252> {
            let mut uri = ArrayTrait::<felt252>::new();
            let uri_len = self.base_uri_len.read();
            let mut index = 0_u32;
            loop {
                if (uri_len == index) {
                    break ();
                }
                uri.append(self.base_uri.read(index));
                index += 1;
            };
            uri
        }

        fn _set_token_uri(ref self: ContractState, uri: Array<felt252>) {
            let mut index = 0_u32;
            self.base_uri_len.write(uri.len());
            loop {
                if (uri.len() == index) {
                    break ();
                }
                self.base_uri.write(index, *uri[index]);
                index += 1;
            };
        }
    }
}
