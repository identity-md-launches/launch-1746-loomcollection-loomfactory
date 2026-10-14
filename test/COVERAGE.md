# Loom acceptance coverage

Run from the repository root with the existing vendored dependencies:

```sh
forge build
forge test
```

The additional suites require no network, fork, FFI, environment variables, or dependency installation. Run counts are declared inline in the test files. The original contributor's tests remain intact.

| Approved requirement | Tests |
| --- | --- |
| Fixed LOOM supply, name, symbol, decimals, ordinary transfers, no privileged minting | `LaunchToken.t.sol`, `LaunchCompatibility.t.sol`; `LaunchTokenInvariant.t.sol` models balances and allowances through random transfers, approvals, delegated spending, zero recipients, insufficient balances/allowances, and forbidden administrative calls. |
| Immutable fee recipients; locked implementation; once-only per-clone initialization | `LoomInitialization.t.sol`; `LoomCloneProperties.t.sol` fuzzes arbitrary replay arguments against two live clones and the implementation after minting, metadata freeze, ownership handover, and pause. A create-fee callback tries to seize the new clone before creation returns. |
| Permissionless factory creation, caller ownership, EIP-1167 runtime, registry, create fee, pauser authority | `LoomFactory.t.sol`; `LoomFactoryInvariant.t.sol` models successful registrations, exact fee receipts, pagination and pause state. Every invalid initializer parameter is exercised through the factory, including rollback of clone code, registration, fee, and deployment nonce. |
| Exact per-token payment, creator price, fixed 40/40/20 split, no fee dust | `LoomMint.t.sol`; `LoomCloneProperties.t.sol` compares one batch with two arbitrary partitions on distinct clones, for both public and reserve minting. Prices include zero and arbitrary wei values; expectations use literal 0.0002/0.0002/0.0001 ETH shares. Incorrect payments, payout rejection, and whole-transaction rollback are covered. |
| Wallet cap, hard supply cap, owner-only reserve capped at floor(supply / 100) | `LoomMint.t.sol`; both collection invariant suites check caps, lifetime public allowances, reserve allowance, NFT balances and conservation. Ownership changes and transfers do not reset allowances. |
| Pause/unpause and owner authorization | `LoomMetadata.t.sol`, `LoomMint.t.sol`, `LoomFactory.t.sol`; the lifecycle model interleaves valid and invalid administrator calls, ownership proposals/replacement/cancellation/acceptance, paused mint failures, and transfers. |
| Provenance once before any mint; reveal seed once; base/unrevealed URI; irreversible metadata freeze | `LoomMetadata.t.sol`; `LoomLifecycleInvariant.t.sol` maintains independent expected metadata and flags, then continues attempting mutations and initializer replay after freeze or handover. The expected token URI is derived from the model. Zero provenance and zero seed are explicitly exercised. |
| ERC-2981 receiver, royalty range 0–1000 bps, rounding | `LoomInitialization.t.sol`, `LoomMetadata.t.sol`; `LoomCloneProperties.t.sol` compares two independently configured royalty quotes over the full uint256 sale-price range against a quotient/remainder oracle that cannot overflow. |
| Events and ERC-721 behavior | Existing suites assert `CollectionCreated`, `Minted`, `FeesDistributed`, `ProvenanceSet`, `Revealed`, `MetadataFrozen`, and `BaseURISet`. New clone properties check token/operator approval isolation and restoration of ownership, approvals, and balances after rejected safe transfers. |
| Callback safety and clone isolation | `LoomAdversarial.t.sol` tests mint/reserve/create reentry, rejecting ETH recipients, rejected batch NFT callbacks, and forwarding NFTs during mint. New properties also exercise a successful nested mint into the other clone to check that guards and accounting are independent. |

## Stateful models

The new invariant suites each run 256 sequences of 96 calls, with unexpected handler reverts treated as failures. Handlers restrict actors and quantities to finite sets for complete accounting; they assert expected reverts from the contracts rather than treating those calls as successful operations or ignoring them.

- `LoomLifecycleInvariant.t.sol` starts with two differently configured clones. Its model predicts ownership, pending ownership, metadata, pause/freeze flags, supply, reserve use, lifetime mints, and individual NFT holders before calling the contracts. It reconciles all ETH paid with the three fee recipients, separately for the two creators. Independent configurations, immutable recipients, and the locked implementation are checked throughout.
- `LoomFactoryInvariant.t.sol` starts with two registered clones and permits up to sixteen. The model records only successful creation calls. Failed creations must leave no code or registry entry, consume no fee, and preserve the next deployment address. The factory must retain no create-fee proceeds.
- `LaunchTokenInvariant.t.sol` models the entire fixed supply across four actors and every allowance between them. It covers finite and unlimited approvals, replacement/revocation, self-transfers, invalid transfers, and failed delegated transfers without allowance loss.

Each new handler has a deterministic sequence test to ensure important successful and rejected operations are reached independently of random selection. The existing collection invariant suite additionally checks a longer-lived mint/transfer/pause workload over two clones.

## Boundaries

These are local contract tests of the approved source. The existing `LaunchCompatibility.t.sol` checks launch constructors, the release roles, supply preservation, and runtime restrictions; it does not replace the service-supplied protected deployment/owner harness. Attestation, admission, deployment, manifest review, and frontend publication are outside this assignment.

Ordinary mint and creation proceeds are forwarded immediately. Rejecting recipients are tested as atomic failures; there is no withdrawal-debt model in this implementation. The existing forced-ETH test checks that unsolicited ETH cannot subsidize mint/create payments. The payment invariants use executions without forced ETH so that a zero retained balance has a precise meaning.

The reserve-mint properties use the accepted implementation's documented interpretation that every reserve token pays the same creator price plus fixed platform fee. Random models do not replace callback tests, and passing tests do not establish correctness for every possible sequence. No implementation defect requiring a finding was reproduced during this contribution.
