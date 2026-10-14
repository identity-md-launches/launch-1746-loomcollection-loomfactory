# Builder verification and review handoff

These are the source contributor's checks and trust assumptions, not the independent review required by the workflow. The separate reviewer should inspect the accepted source and concrete manifest together. Policy and signed-artifact linkage belong to the launch services.

## Reproduction

```sh
forge build
FOUNDRY_FUZZ_SEED=0x569fa88b3a99b6833afb45f5b3ecfc99c735b103e665023ab2bfbfa446f3e671 forge test
forge fmt --check
python3 scripts/export_abi.py --check
```

The suite reports 80 tests under Foundry 1.8.3; its grouped invariant entry covers three invariant functions, 128 runs and depth 64 (8,192 handler calls). Fuzz tests use 512 cases each. No test requires a live chain, a key, environment reads or writes, filesystem cheatcodes, FFI, or a network service. These settings are in the delivered `foundry.toml`; the stated seed is supplied to the runner.

A fresh copy containing only the delivered sources, tests, libraries, configuration, scripts and documentation also passed `forge build --offline`, `forge test --offline --threads 4`, formatting and ABI consistency checks. That copy had no `.imd` inputs or previous build/cache artifacts, and its runner environment retained only tool discovery/home and the requested fuzz seed. All three production artifacts have empty library link-reference maps.

Measured production sizes with the pinned settings:

| Contract | Runtime bytes | Initcode bytes |
| --- | ---: | ---: |
| `LaunchToken` | 1,503 | 2,436 |
| `LoomCollection` | 11,087 | 11,512 |
| `LoomFactory` | 2,527 | 2,839 |

## Coverage and evidence

| Area | Evidence |
| --- | --- |
| Initialization | Implementation permanently locked; factory clones fully configured; owner and outsider replay rejected; invalid initialization rolls back; every configuration bound exercised |
| Clone isolation | Two clones share only immutable fee recipients, with independent ownership, approvals, balances, mint terms, metadata, pause state and counters; implementation storage remains unchanged |
| Payment conservation | Variable creator prices/quantities, zero creator price, coincident recipients, under/overpayment by one wei, batch/individual equivalence, overflow rejection, full rollback on each rejected payment |
| Supply and wallet caps | Multiple callers, repeated batches, transfers that cannot reset allowance, both mint paths sharing supply, reserve rounding down, ownership handover retaining reserve usage, public sellout preventing reserve mint |
| Metadata | Existing/nonexistent token URIs, empty-base fallback, one-way freeze of every metadata setter, provenance blocked after either mint path, one-time seed/provenance even when zero |
| Permissions | Unauthorized callers include outsiders, the creator, factory pauser and factory; owner handover requires acceptance; renunciation clears the pending owner; factory pausing leaves existing clones usable |
| ERC standards | ERC-721 transfers, approvals and clearing; receiver callbacks; ERC-165 interface IDs; ERC-2981 bounded royalties over full uint256 sale prices; standard fixed-supply ERC-20 behavior |
| Callback attacks | Public/reserve cross-reentrancy, all three payout recipients, factory platform reentrancy, second NFT callback rejection, transfer-out during mint, and provenance mutation from the first receiver hook |
| Creation | Exact fee forwarding; atomic rollback of clone code, registry and ETH on failure; retry succeeds; correct 45-byte EIP-1167 runtime; creation enumeration and pagination bounds |
| Launch compatibility | Actual release owner constructor values; fixed launch-token supply preserved; application recipients/admins explicit; constructor accepts as-yet undeployed implementation; runtime size and PUSH-aware forbidden-opcode scan |
| Stateful behavior | Two clones and four wallets; randomized public/reserve mints, transfers, pauses, metadata updates, freezes and wrong payments; balance conservation and cap checks after every action |

All funds-movement paths are guarded, with mint counters and batch supply reserved before receiver hooks, and the factory registry established before forwarding the create fee. Failed calls revert atomically. There is no withdrawal queue, sweep permission, signature scheme, external oracle, mutable implementation or privileged price/fee setter.

## Deliberate trust and operating limits

1. **Immediate ETH forwarding:** a recipient rejecting or exhausting gas blocks new mints for that collection; a rejecting platform blocks factory creation. In-flight tokens, funds and accounting all roll back. Recipients are fixed and must be able to accept ETH. This is required operational compatibility for the specified immediate payouts, not a deferred-debt design.
2. **Owner-chosen metadata and seed:** provenance is a stored commitment, not verification of the dataset. Reveal seed is an off-chain record, not verifiable randomness; it cannot support an on-chain fair lottery or shuffle claim. Metadata can be withheld or changed until freeze. Freeze may intentionally lock empty fields. IPFS availability remains an off-chain responsibility.
3. **Reserve interpretation:** the same full payment formula applies to public and reserve mints because the workflow charges per minted token and specifies creator payment per mint. Reserve allowance rounds down, is not held aside from public supply, and does not consume the public wallet allowance. These semantics are documented for review and frontend use.
4. **Administration:** a collection owner can pause minting, renounce ownership, freeze metadata, and use the lifetime reserve allowance. Ownership does not move the creator's proceeds/royalties. The factory pauser is immutable; there is no recovery mechanism for lost authority. Pauses do not freeze transfers.
5. **Clone provenance:** a clone initialized outside this factory can use the same implementation without paying a create fee. Only the factory registry demonstrates creation through LoomFactory. Bare clones initialized in a later transaction can be claimed by any first caller; the factory avoids that gap atomically.
6. **Implementation binding:** the factory checks live code and matching platform on first use, but the manifest must point to the accepted immutable implementation. Constructors do not call outside contracts, allowing the launch's empty-chain constructor checks. Services and reviewers verify artifact linkage.
7. **Minting is linear in quantity:** OpenZeppelin ERC-721 performs a safe mint per token. There is no arbitrary protocol batch limit; callers estimate gas and split large mints. The only unbounded transaction loops are caller-selected mint batches, which fail atomically if gas is exhausted. Factory pagination is bounded at 100 entries.
8. **No enforced secondary-sale royalty:** ERC-2981 provides a quote to marketplaces. It does not intercept transfers or force payment. Forced ETH and mistakenly transferred unrelated assets have no administrative recovery path.

The builder used the supplied protected test definitions as acceptance data and added local launch compatibility checks. The actual protected harness depends on service-provided artifact values and a separate owner-check helper not present here; it is not represented as having run locally. No manifest, live deployment, explorer verification, external independent audit, Slither run or Mythril run is claimed.

Foundry's build lint reports possible reentrancy and arbitrary ETH sends around inherited guards and payout events. The relevant external calls were reviewed: mint/reserve/create entry points have OpenZeppelin reentrancy guards, sensitive accounting is updated before callbacks, ETH recipients are immutable/fixed at initialization, and failures revert. Dedicated malicious-receiver tests exercise these paths. The linter also sees event ordering through inherited calls; the emitted successful-transaction semantics are documented in the ABI guide. These annotations do not suppress lint warnings or replace independent review.
