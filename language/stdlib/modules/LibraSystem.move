address 0x1 {

module LibraSystem {
    use 0x1::CoreAddresses;
    use 0x1::Errors;
    use 0x1::LibraConfig::{Self, ModifyConfigCapability};
    use 0x1::Option::{Self, Option};
    use 0x1::Signer;
    use 0x1::ValidatorConfig;
    use 0x1::Vector;
    use 0x1::Roles;
    use 0x1::LibraTimestamp;

    struct ValidatorInfo {
        addr: address,
        consensus_voting_power: u64,
        config: ValidatorConfig::Config,
    }

    resource struct CapabilityHolder {
        cap: ModifyConfigCapability<LibraSystem>,
    }

    struct LibraSystem {
        // The current consensus crypto scheme.
        scheme: u8,
        // The current validator set. Updated only at epoch boundaries via reconfiguration.
        validators: vector<ValidatorInfo>,
    }
    spec struct LibraSystem {
        /// Validators have unique addresses.
        invariant
            forall i in 0..len(validators), j in 0..len(validators):
                validators[i].addr == validators[j].addr ==> i == j;
    }

    spec module {
        /// After genesis, the `LibraSystem` configuration is published, as well as the capability
        /// to modify it.
        invariant [global] LibraTimestamp::is_operating() ==>
            LibraConfig::spec_is_published<LibraSystem>() &&
            exists<CapabilityHolder>(CoreAddresses::LIBRA_ROOT_ADDRESS());
    }

    /// The `CapabilityHolder` resource was not in the required state
    const ECAPABILITY_HOLDER: u64 = 0;
    /// Tried to add a validator with an invalid state to the validator set
    const EINVALID_PROSPECTIVE_VALIDATOR: u64 = 1;
    /// Tried to add an existing validator to the validator set
    const EALREADY_A_VALIDATOR: u64 = 2;
    /// An operation was attempted on a non-active validator
    const ENOT_AN_ACTIVE_VALIDATOR: u64 = 3;
    /// The validator operator is not the operator for the specified validator
    const EINVALID_TRANSACTION_SENDER: u64 = 4;
    /// An out of bounds index for the validator set was encountered
    const EVALIDATOR_INDEX: u64 = 5;

    ///////////////////////////////////////////////////////////////////////////
    // Setup methods
    ///////////////////////////////////////////////////////////////////////////

    // This can only be invoked by the ValidatorSet address to instantiate
    // the resource under that address.
    // It can only be called a single time. Currently, it is invoked in the genesis transaction.
    public fun initialize_validator_set(
        config_account: &signer,
    ) {
        LibraTimestamp::assert_genesis();
        Roles::assert_libra_root(config_account);

        let cap = LibraConfig::publish_new_config_and_get_capability<LibraSystem>(
            config_account,
            LibraSystem {
                scheme: 0,
                validators: Vector::empty(),
            },
        );
        assert(
            !exists<CapabilityHolder>(CoreAddresses::LIBRA_ROOT_ADDRESS()),
            Errors::already_published(ECAPABILITY_HOLDER)
        );
        move_to(config_account, CapabilityHolder { cap })
    }
    spec fun initialize_validator_set {
        modifies global<LibraConfig::LibraConfig<LibraSystem>>(CoreAddresses::LIBRA_ROOT_ADDRESS());
        include LibraTimestamp::AbortsIfNotGenesis;
        include Roles::AbortsIfNotLibraRoot{account: config_account};
        let config_addr = Signer::spec_address_of(config_account);
        aborts_if LibraConfig::spec_is_published<LibraSystem>() with Errors::ALREADY_PUBLISHED;
        aborts_if exists<CapabilityHolder>(config_addr) with Errors::ALREADY_PUBLISHED;
        ensures exists<CapabilityHolder>(config_addr);
        ensures LibraConfig::spec_is_published<LibraSystem>();
        ensures len(spec_get_validator_set()) == 0;
    }

    // This copies the vector of validators into the LibraConfig's resource
    // under ValidatorSet address
    fun set_validator_set(value: LibraSystem) acquires CapabilityHolder {
        LibraTimestamp::assert_operating();
        assert(
            exists<CapabilityHolder>(CoreAddresses::LIBRA_ROOT_ADDRESS()),
            Errors::not_published(ECAPABILITY_HOLDER)
        );
        LibraConfig::set_with_capability_and_reconfigure<LibraSystem>(
            &borrow_global<CapabilityHolder>(CoreAddresses::LIBRA_ROOT_ADDRESS()).cap,
            value
        )
    }

    spec fun set_validator_set {
        pragma opaque = true;
        modifies global<LibraConfig::LibraConfig<LibraSystem>>(CoreAddresses::LIBRA_ROOT_ADDRESS());
        include LibraTimestamp::AbortsIfNotOperating;
        include LibraConfig::AbortsIfNotPublished<LibraSystem>;
        include AbortsIfNoCapabilityHolder;
        ensures global<LibraConfig::LibraConfig<LibraSystem>>(CoreAddresses::LIBRA_ROOT_ADDRESS()).payload == value;
    }

    spec schema AbortsIfNoCapabilityHolder {
        aborts_if !exists<CapabilityHolder>(CoreAddresses::LIBRA_ROOT_ADDRESS()) with Errors::NOT_PUBLISHED;
    }

    ///////////////////////////////////////////////////////////////////////////
    // Methods operating the Validator Set config callable by the libra root account
    ///////////////////////////////////////////////////////////////////////////

    // Adds a new validator, this validator should met the validity conditions
    // If successful, a NewEpochEvent is fired
    public fun add_validator(
        lr_account: &signer,
        account_address: address
    ) acquires CapabilityHolder {
        LibraTimestamp::assert_operating();
        Roles::assert_libra_root(lr_account);
        // A prospective validator must have a validator config resource
        assert(ValidatorConfig::is_valid(account_address), Errors::invalid_argument(EINVALID_PROSPECTIVE_VALIDATOR));

        let validator_set = get_validator_set();
        // Ensure that this address is not already a validator
        assert(
            !is_validator_(account_address, &validator_set.validators),
            Errors::invalid_argument(EALREADY_A_VALIDATOR)
        );
        // it is guaranteed that the config is non-empty
        let config = ValidatorConfig::get_config(account_address);
        Vector::push_back(&mut validator_set.validators, ValidatorInfo {
            addr: account_address,
            config, // copy the config over to ValidatorSet
            consensus_voting_power: 1,
        });

        set_validator_set(validator_set);
    }
    spec fun add_validator {
        /// TODO: times out arbitrarily, while succeeding quickly some other times.
//        pragma verify = false;
        modifies global<LibraConfig::LibraConfig<LibraSystem>>(CoreAddresses::LIBRA_ROOT_ADDRESS());
        include LibraTimestamp::AbortsIfNotOperating;
        // TODO (dd) Junkil applies this at the end of the file.
        // include Roles::AbortsIfNotLibraRoot{account: lr_account};
        aborts_if !ValidatorConfig::spec_is_valid(account_address) with Errors::INVALID_ARGUMENT;
        aborts_if spec_is_validator(account_address) with Errors::INVALID_ARGUMENT;
        ensures spec_is_validator(account_address);
    }

    spec fun add_validator {
        let vs = spec_get_validator_set();
        // TODO (dd) (Issue #5739) BUG: "old" doesn't seem to do anything here.
        //     Bug will cause eq_push_back to be violated.
        // let ovs = old(spec_get_validator_set());
        ensures Vector::eq_push_back(vs,
                                     // ovs,   // DD replaced with next line because of bug.
                                     old(spec_get_validator_set()),
                                     ValidatorInfo {
                                         addr: account_address,
                                         config: ValidatorConfig::spec_get_config(account_address),
                                         consensus_voting_power: 1,
                                      }
                                   );
    }


    // Removes a validator, only callable by the libra root account
    // If successful, a NewEpochEvent is fired
    public fun remove_validator(
        lr_account: &signer,
        account_address: address
    ) acquires CapabilityHolder {
        LibraTimestamp::assert_operating();
        Roles::assert_libra_root(lr_account);
        let validator_set = get_validator_set();
        // Ensure that this address is an active validator
        let to_remove_index_vec = get_validator_index_(&validator_set.validators, account_address);
        assert(Option::is_some(&to_remove_index_vec), Errors::invalid_argument(ENOT_AN_ACTIVE_VALIDATOR));
        let to_remove_index = *Option::borrow(&to_remove_index_vec);
        // Remove corresponding ValidatorInfo from the validator set
        _  = Vector::swap_remove(&mut validator_set.validators, to_remove_index);

        set_validator_set(validator_set);
    }
    spec fun remove_validator {
        modifies global<LibraConfig::LibraConfig<LibraSystem>>(CoreAddresses::LIBRA_ROOT_ADDRESS());
        include LibraTimestamp::AbortsIfNotOperating;
        // TODO (dd) Junkil applies this at end of file.
        // include Roles::AbortsIfNotLibraRoot{account: lr_account};
        aborts_if !spec_is_validator(account_address) with Errors::INVALID_ARGUMENT;
        ensures !spec_is_validator(account_address);
    }
    spec fun remove_validator {
        let vs = spec_get_validator_set();
        // TODO (dd) (Issue #5739) BUG: I think the "old" is getting lost.
        // let ovs = old(spec_get_validator_set());
        // TODO (dd) all this times out.
        // ensures len(vs) == len(ovs) - 1;
        // TODO (dd) BUG: The next property holds trivially because
        // ensures forall vi in vs where vi.addr != account_address: exists ovi in ovs: vi == ovi;
        ensures forall vi in vs where vi.addr != account_address: exists ovi in old(spec_get_validator_set()): vi == ovi;
        /// Removed validator should no longer be valid.
        ensures !spec_is_validator(account_address);
    }

    // For a calling validator's operator copy the information from ValidatorConfig into the ValidatorSet.
    // This function makes no changes to the size or the members of the set.
    // If the config in the ValidatorSet changes, a NewEpochEvent is fired.
    public fun update_config_and_reconfigure(
        operator_account: &signer,
        validator_address: address,
    ) acquires CapabilityHolder {
        Roles::assert_validator_operator(operator_account);
        assert(
            ValidatorConfig::get_operator(validator_address) == Signer::address_of(operator_account),
            Errors::invalid_argument(EINVALID_TRANSACTION_SENDER)
        );
        let validator_set = get_validator_set();
        let to_update_index_vec = get_validator_index_(&validator_set.validators, validator_address);
        assert(Option::is_some(&to_update_index_vec), Errors::invalid_argument(ENOT_AN_ACTIVE_VALIDATOR));
        let to_update_index = *Option::borrow(&to_update_index_vec);
        let is_validator_info_updated = update_ith_validator_info_(&mut validator_set.validators, to_update_index);
        if (is_validator_info_updated) {
            set_validator_set(validator_set);
        }
    }
    spec fun update_config_and_reconfigure {
        // TODO (dd): This times out.  It will complete quickly IF (1) all aborts_ifs here are commented out,
        // and (2) the last property in the second spec fun (that the proper validator set entry is properly
        // updated) is commented out.
        pragma verify_duration_estimate = 100;
        include Roles::AbortsIfNotValidatorOperator{account: operator_account};
        include ValidatorConfig::AbortsIfNoValidatorConfig{addr: validator_address};
        aborts_if ValidatorConfig::spec_get_operator(validator_address) != Signer::spec_address_of(operator_account)
            with Errors::INVALID_ARGUMENT;
        aborts_if !LibraConfig::spec_is_published<LibraSystem>();
        aborts_if !spec_is_validator(validator_address) with Errors::INVALID_ARGUMENT;
        aborts_if !ValidatorConfig::spec_is_valid(validator_address) with Errors::INVALID_ARGUMENT;
    }

    /// *Informally:* Does not change the length of the validator set, only
    /// changes ValidatorInfo for validator_address, and doesn't change
    /// any addresses.
    ///
    /// This is a separate spec fun so we can use multiple lets.
    /// TODO: Look at called procedures to understand this better.  Also,
    ///    look at transactions.
    spec fun update_config_and_reconfigure {
        // TODO (dd) BUG: Translated boogie does not have old, so vs == ovs.
        //    Property is trivial!
        let vs = spec_get_validator_set();
        // let ovs = old(spec_get_validator_set());
        ensures len(vs) == len(old(spec_get_validator_set()));
        /// No addresses change
        ensures forall i in 0..len(vs): vs[i].addr == old(spec_get_validator_set())[i].addr;
        /// If the validator info address is not the one we're changing, the info does not change.
        ensures forall i in 0..len(vs) where old(spec_get_validator_set())[i].addr != validator_address:
                         vs[i] == old(spec_get_validator_set())[i];
        // It updates the correct entry in the correct way (have not been able to verify)
        ensures forall i in 0..len(spec_get_validator_set())
                 where old(spec_get_validator_set())[i].addr == validator_address:
             old(spec_get_validator_set())[i].config == ValidatorConfig::get_config(vs[i].addr);
    }


    ///////////////////////////////////////////////////////////////////////////
    // Publicly callable APIs: getters
    ///////////////////////////////////////////////////////////////////////////

    // This returns a copy of the LibraSystem resource with current validator set.
    // TODO (dd): Can this be private?
    public fun get_validator_set(): LibraSystem {
        LibraConfig::get<LibraSystem>()
    }
    /// Doesn't actually get the validator set. It gets the
    /// LibraSystem config, which contains the validator set.
    spec fun get_validator_set {
        pragma opaque;
        include LibraConfig::AbortsIfNotPublished<LibraSystem>;
        ensures result == LibraConfig::spec_get<LibraSystem>();
    }
    /// Actually gets the validator set, unlike get_validator_set
    spec module {
        define spec_get_validator_set(): vector<ValidatorInfo> {
            LibraConfig::spec_get<LibraSystem>().validators
        }
    }


    // Return true if addr is a current validator
    public fun is_validator(addr: address): bool {
        is_validator_(addr, &get_validator_set().validators)
    }
    spec fun is_validator {
        pragma opaque;
        include LibraConfig::AbortsIfNotPublished<LibraSystem>;
        ensures result == spec_is_validator(addr);
    }
    spec define spec_is_validator(addr: address): bool {
        exists v in spec_get_validator_set(): v.addr == addr
    }

    // Returns validator config
    // If the address is not a validator, abort
    public fun get_validator_config(addr: address): ValidatorConfig::Config {
        let validator_set = get_validator_set();
        let validator_index_vec = get_validator_index_(&validator_set.validators, addr);
        assert(Option::is_some(&validator_index_vec), Errors::invalid_argument(ENOT_AN_ACTIVE_VALIDATOR));
        *&(Vector::borrow(&validator_set.validators, *Option::borrow(&validator_index_vec))).config
    }
    spec fun get_validator_config {
        pragma opaque;
        include LibraConfig::AbortsIfNotPublished<LibraSystem>;
        aborts_if !spec_is_validator(addr) with Errors::INVALID_ARGUMENT;
        ensures
            exists info in LibraConfig::spec_get<LibraSystem>().validators where info.addr == addr:
                result == info.config;
    }

    // Return the size of the current validator set
    public fun validator_set_size(): u64 {
        Vector::length(&get_validator_set().validators)
    }
    spec fun validator_set_size {
        pragma opaque;
        include LibraConfig::AbortsIfNotPublished<LibraSystem>;
        ensures result == len(spec_get_validator_set());
    }

    // This function is used in transaction_fee.move to distribute transaction fees among validators
    public fun get_ith_validator_address(i: u64): address {
        assert(i < validator_set_size(), Errors::invalid_argument(EVALIDATOR_INDEX));
        Vector::borrow(&get_validator_set().validators, i).addr
    }
    spec fun get_ith_validator_address {
        pragma opaque;
        include LibraConfig::AbortsIfNotPublished<LibraSystem>;
        aborts_if i >= len(spec_get_validator_set()) with Errors::INVALID_ARGUMENT;
        ensures result == spec_get_validator_set()[i].addr;
    }

    ///////////////////////////////////////////////////////////////////////////
    // Private functions
    ///////////////////////////////////////////////////////////////////////////

    // Get the index of the validator by address in the `validators` vector
    fun get_validator_index_(validators: &vector<ValidatorInfo>, addr: address): Option<u64> {
        let size = Vector::length(validators);
        let i = 0;
        while ({
            spec {
                assert i <= size;
                assert forall j in 0..i: validators[j].addr != addr;
            };
            (i < size)
        })
        {
            let validator_info_ref = Vector::borrow(validators, i);
            if (validator_info_ref.addr == addr) {
                spec {
                    assert validators[i].addr == addr;
                };
                return Option::some(i)
            };
            i = i + 1;
        };
        spec {
            assert i == size;
            assert forall j in 0..size: validators[j].addr != addr;
        };
        return Option::none()
    }
    spec fun get_validator_index_ {
        pragma opaque;
        aborts_if false;
        let size = len(validators);
        ensures (forall i in 0..size: validators[i].addr != addr) ==> Option::is_none(result);
        ensures
            (exists i in 0..size: validators[i].addr == addr) ==>
                Option::is_some(result) &&
                {
                    let at = Option::spec_get(result);
                    0 <= at && at < size && validators[at].addr == addr
                };
    }

    // Updates ith validator info, if nothing changed, return false.
    // This function should never throw an assertion.
    fun update_ith_validator_info_(validators: &mut vector<ValidatorInfo>, i: u64): bool {
        let size = Vector::length(validators);
        if (i >= size) {
            return false
        };
        let validator_info = Vector::borrow_mut(validators, i);
        if (!ValidatorConfig::is_valid(validator_info.addr)) {
            return false
        };
        // TODO (dd): Why can't it abort here?  Right now, ValidatorConfig says validators
        //    stay published forever, but I wonder if that's reasonable.
        //    Calling context checks validator role, and there probably should be an
        //    invariant that validator role ==> validator config.
        let new_validator_config = ValidatorConfig::get_config(validator_info.addr);
        // check if information is the same
        let config_ref = &mut validator_info.config;

        if (config_ref == &new_validator_config) {
            return false
        };
        *config_ref = new_validator_config;

        true
    }
    spec fun update_ith_validator_info_ {
        pragma opaque;
        aborts_if false;
        let new_validator_config = ValidatorConfig::spec_get_config(validators[i].addr);
        ensures
            result ==
                (i < len(validators) &&
                 ValidatorConfig::spec_is_valid(validators[i].addr) &&
                 new_validator_config != old(validators[i].config));
        ensures
            result ==>
                validators == update_vector(
                    old(validators),
                    i,
                    update_field(old(validators[i]), config, new_validator_config)
                );
        ensures !result ==> validators == old(validators);
    }

    fun is_validator_(addr: address, validators_vec_ref: &vector<ValidatorInfo>): bool {
        Option::is_some(&get_validator_index_(validators_vec_ref, addr))
    }
    spec fun is_validator_ {
        pragma opaque;
        aborts_if false;
        ensures result == (exists v in validators_vec_ref: v.addr == addr);
    }


    /// # Module specifications

    // TODO(wrwg): integrate this into module documentation

    // Each validator owner stores a Config in ValidatorConfig module.
    // The validator may set the operator (another libra account), this operator will
    // be able to set the values of the validator's Config.
    // The 0xA550C18 address stores the set of validator's configs that are currently active
    // in the Libra Protocol. The LibraRoot account may add/remove validators to/from the set.
    // The operator of a validator that is currently in the validator set can modify
    // the ValidatorInfo for its validator (only), and set the config for the
    // modified validator set to the new validator set and trigger a reconfiguration.
    spec module {
        pragma verify;
    }

    // The permission "{Add, Remove} Validator" is granted to LibraRoot [B22].
    spec module {
       apply Roles::AbortsIfNotLibraRoot{account: lr_account} to add_validator, remove_validator;
    }

    // This restricts the set of functions that can modify the validator set config.
    // To specify proper access, it is sufficient to show the following conditions,
    // which are all specified and verified in the spec fun's
    // 1. `initialize` aborts if not called during genesis
    // 2. `add_validator` adds a validator without changing anything else in the validator set
    //    and only completes successfully if the signer is Libra Root.
    // 3. `remove_validator` removes a validator without changing anything else and only
    //    completes successfully if the signer is Libra Root
    // 4. `update_config_and_reconfigure` changes only entry for the validator it's supposed
    //    to update, and only completes successfully if the signer is the validator operator
    //    for that validator.
    // set_validator_set is a private function, so it does not have to preserve the property.
    spec schema ValidatorSetConfigRemainsSame {
        /// Only {add, remove} validator may change the set of validators in the configuration.
        ensures spec_get_validator_set() == old(spec_get_validator_set());
    }
    spec module {
        apply ValidatorSetConfigRemainsSame to *, *<T>
           except add_validator, remove_validator, update_config_and_reconfigure,
               initialize_validator_set, set_validator_set;
    }

}
}
