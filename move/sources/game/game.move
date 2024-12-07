/// Game is responsible for executing the flow for placing bets and wins.
/// The game module plays a similar role as Pool in deepbookv3.
module openplay::game;

use openplay::balance_manager::BalanceManager;
use openplay::coin_flip::{Self, CoinFlip};
use openplay::state::State;
use openplay::vault::Vault;
use std::string::String;
use sui::random::Random;

// === Errors ===
const EInvalidGameType: u64 = 1;
const EInvalidStake: u64 = 2;
const EInsufficientFunds: u64 = 3;

// === Structs ===
public enum GameType has store, copy, drop {
    SlotMachine,
    CoinFlip,
}

public enum Interaction {
    // SlotMachineInteraction(slot_machine::Interaction),
    CoinFlipInteraction(coin_flip::Interaction),
}

public struct Game has key {
    id: UID,
    game_type: GameType,
    // slot_machine: Option<SlotMachine>,
    coin_flip: Option<CoinFlip>,
    vault: Vault,
    state: State,
    target_balance: u64,
}

// === Public-Mutative Functions ===

/// Interact entry function that can be used when the game is of type CoinFlip.
/// Enums can not be used in entry functions therefore all parameters need to be provided.
/// Parameters that are not needed for the specific interact will be ignored.
entry fun interact_coin_flip(
    self: &mut Game,
    balance_manager: &mut BalanceManager,
    interact_name: String,
    stake: u64,
    prediction: String,
    random: &Random,
    ctx: &mut TxContext,
): coin_flip::Interaction {
    // Verify that it is indeed a coin flip game
    assert!(self.game_type == GameType::CoinFlip, EInvalidGameType);
    // Make sure the vault is up to date (end of day is processed for previous days)
    self.update_vault(ctx);
    // Make sure we have enough funds in the vault to play this game
    self.ensure_sufficient_funds(self.coin_flip.borrow().max_payout(stake));
    // Interact with coin flip and record any transactions made
    let mut interact = coin_flip::new_interact(
        interact_name,
        balance_manager.id(),
        prediction,
        stake,
    );
    self.coin_flip.borrow_mut().interact(&mut interact, &mut random.new_generator(ctx));
    // Process transactions by state
    let (credit_balance, debit_balance, owner_fee, protocol_fee) = self
        .state
        .process_transactions(&interact.transactions(), balance_manager.id(), ctx);

    // Settle the balances in vault
    self.vault.settle_balance_manager(credit_balance, debit_balance, balance_manager);
    self.vault.process_fees(owner_fee, protocol_fee);

    interact
}

/// Stake money in the protocol to participate in the house winnings.
/// The stake is first added to the account's inactive stake, and is only activated in the next epoch.
public fun stake(
    self: &mut Game,
    balance_manager: &mut BalanceManager,
    amount: u64,
    ctx: &mut TxContext,
) {
    // Make sure the vault is up to date (end of day is processed for previous days)
    self.update_vault(ctx);
    assert!(amount > 0, EInvalidStake);
    let (credit_balance, debit_balance) = self
        .state
        .process_stake(balance_manager.id(), amount, ctx);

    self.vault.settle_balance_manager(credit_balance, debit_balance, balance_manager);
}

/// Withdraws the stake from the current game. This only goes into effect in the next epoch.
public fun unstake(self: &mut Game, balance_manager: &mut BalanceManager, ctx: &mut TxContext) {
    // Make sure the vault is up to date (end of day is processed for previous days)
    self.update_vault(ctx);

    let (credit_balance, debit_balance) = self.state.process_unstake(balance_manager.id(), ctx);
    self.vault.settle_balance_manager(credit_balance, debit_balance, balance_manager);
}

// == Private Functions ==
/// The first time this gets called on a new epoch, the end of the day procedure is initiated for the last known epoch.
/// The vault saves the end of day balance for the house and resets to the target balance if there are enough funds available.
/// Note: there can be a number of epochs in between without any activity.
fun update_vault(self: &mut Game, ctx: &TxContext) {
    let (epoch_switch, prev_epoch, end_balance) = self.vault.update(self.target_balance, ctx);

    if (epoch_switch) {
        let profits: u64;
        let losses: u64;
        if (end_balance > self.target_balance) {
            profits = end_balance - self.target_balance;
            losses = 0;
        } else {
            losses = end_balance - self.target_balance;
            profits = 0;
        };
        self.state.process_end_of_day(prev_epoch, profits, losses, end_balance, ctx);
    }
}

/// Ensures that the vault can cover `max_payout` with the play balance
fun ensure_sufficient_funds(self: &Game, max_payout: u64) {
    assert!(self.vault.play_balance() >= max_payout, EInsufficientFunds)
}