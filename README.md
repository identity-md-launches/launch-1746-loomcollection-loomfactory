# Loom contracts

Loom is an NFT collection launchpad for Sepolia (chain ID **11155111**). This contribution implements `LoomCollection`, `LoomFactory`, and the required standard `LaunchToken`, with local tests and generated ABI files. The separate manifest and independent review assignments follow this source contribution. Publication, attestation, admission, deployment and the frontend are service/later-stage responsibilities; this repository does not broadcast transactions or create `launch.json`.

## Build and verify

Run from the repository root with Foundry and Solidity 0.8.26 installed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x569fa88b3a99b6833afb45f5b3ecfc99c735b103e665023ab2bfbfa446f3e671 forge test
forge fmt --check
python3 scripts/export_abi.py --check
```

`foundry.toml` pins Solidity 0.8.26, Cancun, the optimizer at 200 runs, IR compilation, and `bytecode_hash = "none"`. No FFI or filesystem cheatcode permissions are enabled. Dependencies are ordinary files under `lib/`; builds and tests need no network, dependency installation, secrets, RPC endpoint or environment configuration. The fuzz-seed environment variable above is a Foundry runner option; no test reads or changes environment variables.

OpenZeppelin Contracts and Contracts Upgradeable are vendored from **v5.0.2**, and forge-std from **v1.9.7**. [dependencies.json](dependencies.json) records upstream release URLs and downloaded archive SHA-256 digests. Upstream licenses are retained in each library directory. The collection uses OpenZeppelin's initializer-based ERC-721 as the equivalent to ERC721A permitted by the workflow; mint gas grows with quantity. Start with small batches and estimate gas before submitting.

To refresh ABI exports after a source change, run `forge build` followed by `python3 scripts/export_abi.py`. The export script uses only the Python standard library and local build artifacts.

## Deployment parameters

The manifest assignment should describe these constructors in dependency order. All are nonpayable, accept only static arguments, and perform no external calls or address-code checks in their constructors.

| Contract | Constructor parameters, in order | Release values |
| --- | --- | --- |
| `LaunchToken` | none | Name `Loom`, symbol `LOOM`, 18 decimals; fixed supply `1000000000000000000000000000` |
| `LoomCollection` | `address platform`, `address reserve` | `$owner`, `$owner` |
| `LoomFactory` | `address implementation_`, `address platform`, `address pauser_` | `$contract:LoomCollection`, `$owner`, `$owner` |

For this release, `$owner` is **0x7efaa4fe311657ac972b6f1ce05a2ee460805fdf**. It is supplied through constructor arguments; production contracts contain no hard-coded administrator. The collection implementation has initialization permanently disabled and therefore has no collection owner. Each later clone's owner is the wallet/contract calling `createCollection`, as the workflow requires. That caller may choose a different creator, who receives mint proceeds and royalties.

`LoomFactory` deliberately validates that the implementation has code and that its `PLATFORM()` matches the factory on each creation, rather than in its constructor. The manifest/reviewer must bind it to the accepted `LoomCollection` artifact. The implementation address, platform, reserve and factory pauser cannot change after deployment.

`LaunchToken` mints its complete fixed supply to its deployer, the launch pipeline's factory. It has no owner, extra minting, fees, pause, blocklist, burn entry point or upgrade functions. The pipeline handles token allocations and its ETH-paired liquidity pool (fee 12500, tick spacing 60, legacy initial-price field `79228162514264337593543950336`). Opening price is derived by the service from the approved policy. The NFT contracts receive no launch allocation and do not depend on LOOM balances.

## Collection creation and mint payments

Anyone can call:

```text
createCollection(name, symbol, maxSupply, mintPriceWei, maxPerWallet, creator, royaltyBps)
msg.value = 0.002 ether
```

The factory deploys an OpenZeppelin EIP-1167 clone, initializes it in the same transaction, adds it to `collections` and `isCollection`, emits `CollectionCreated`, and forwards the entire create fee to `PLATFORM`. Missing fees and overpayments revert. Failed initialization or payment rolls back the clone and registry entry. Creation cannot be front-run with a competing initialization because no uninitialized clone is exposed between transactions. An independently deployed bare clone must also be initialized atomically; its public initializer is otherwise first-come, first-served. Only collections in the factory registry have paid its create fee.

Names and symbols must be nonempty. Supply must be positive; the wallet cap must be in `[1, maxSupply]`; creator and owner must be nonzero. `mintPriceWei` is chosen per collection, defaults to 0 in the intended UI, and must allow addition of the fixed platform fee without uint256 overflow. `royaltyBps` is in `[0, 1000]`, with a UI default of 500 (5%). These values have no setters after initialization. A batch whose total price overflows uint256 also reverts.

Both `mint(quantity)` and owner-only `reserveMint(quantity)` require positive quantity and exactly:

```text
msg.value = (mintPriceWei + 500000000000000) * quantity
```

Each minted token pays:

| Recipient | Per-token ETH received |
| --- | --- |
| `creator` | `mintPriceWei + 0.0002 ETH` |
| `PLATFORM` | `0.0002 ETH` |
| `RESERVE` | `0.0001 ETH` |

The platform fee is exactly 0.0005 ETH, split 40/40/20. The integer per-token shares add exactly to that fee without rounding dust, even across different batch sizes. Coincident recipients receive the sum of their shares. No contract retains proceeds after a successful transaction. A creator price of 0 still requires the platform fee.

All recipient calls must accept ETH. A rejecting recipient reverts the entire mint (or creation for its platform recipient), restoring the caller's payment, tokens, counters, and earlier payouts. This direct-forwarding design intentionally provides no deferred debts, withdrawal queue or owner sweep. Funds forcibly sent to a contract do not count as payment and cannot be recovered through an admin function.

## Caps, ownership and assumptions

- Token IDs start at **1** and increase consecutively. There is no burn function. `totalSupply` includes public and owner reserve mints and never exceeds `maxSupply`.
- `mintedPerWallet` tracks lifetime public mints by caller, rather than current holdings. Sending tokens away does not restore the allowance. Transfers may take a wallet's holdings above the cap; this is a mint limit, not a transfer restriction or a Sybil defense.
- Reserve allowance is **floor(maxSupply / 100)** across the collection's whole lifetime, shared across ownership changes. Collections with supply below 100 have no reserve allowance. Reserve minting goes to the current owner, does not consume public wallet allowance, and shares the hard supply cap. Public minting can sell out the entire collection before its owner uses the reserve allowance.
- **Reserve payment interpretation:** the workflow says the fee applies to every minted token and specifies the creator payment per mint. Reserve mints therefore use the same full price formula as public mints. There is no fee-free mint path or additional fee.
- Collection owners can pause/unpause both mint paths, manage metadata until freeze, exercise the reserve allowance, and transfer ownership through a two-step handover. A pending owner must call `acceptOwnership`. Setting a pending owner to zero cancels a pending handover. The creator and royalty receiver do not change on handover.
- OpenZeppelin's explicit `renounceOwnership` remains available. It clears the pending owner and permanently disables all owner actions. Renouncing while paused permanently disables minting; renouncing before metadata completion leaves it incomplete. Renouncing does not change the creator or the fixed royalty rate.
- Pausing affects minting only; approvals and transfers remain usable. The factory's immutable pauser can pause/unpause **creation only**, with no power over existing clones, prices, recipients or implementations. Losing that key while paused prevents future factory creation.
- Clones share immutable fee recipients from the implementation but have separate collection storage. There is no upgrade function, proxy admin, replacement implementation or arbitrary delegatecall entry point. The 45-byte child clone performs EIP-1167 delegation to its fixed implementation. The three launch artifacts themselves contain no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`, as checked locally against the supplied floor's opcode rules.

## Metadata and royalties

Every clone starts with empty base and unrevealed URIs. For an existing token, `tokenURI` returns `unrevealedURI` while base URI is empty; otherwise it returns `baseURI + decimal(tokenId) + ".json"`. Include the final `/` in an IPFS directory URI. Unminted IDs revert.

The owner can set provenance once, only while supply is zero (including no reserve mints). The owner can record one reveal seed before metadata freeze, before or after minting. Separate flags enforce one-time assignment even for `bytes32(0)`. A zero commitment is accepted but does not provide a useful provenance claim. The seed records an owner-chosen off-chain value: it is not verifiable randomness, does not shuffle IDs, and does not prove a fair reveal. The owner can withhold it. Art creation, ordering, seed interpretation and verification of commitments occur off-chain.

`freezeMetadata` irreversibly locks **base URI, unrevealed URI, provenance and reveal seed**, even if any are still empty or unset. It does not block minting or ERC-721 transfers. Content availability still depends on IPFS pinning; freezing an HTTP URL would not freeze its server's contents.

ERC-2981 returns `creator` and `floor(salePrice * royaltyBps / 10000)` using full-precision multiplication. Quotes work for any token ID, including an unminted one. The rate and receiver are fixed, at most 10%; marketplaces choose whether to honor royalties. ERC-165, ERC-721 and ERC-721 metadata are supported. ERC-721 Enumerable is not advertised; the frontend should index standard `Transfer` events and verify current `ownerOf` values.

## After launch

No external-service subscriptions, keys, registries or oracle settings are needed by these contracts.

1. The deployment service binds the accepted source and manifest, publishes/verifies the artifacts, and hands attested Sepolia addresses to the frontend. The independent reviewer checks the concrete constructors, role recipients and cloned implementation linkage before release.
2. The frontend checks chain ID 11155111, uses the attested factory, paginates `getCollections(offset, limit)` with limit at most **100**, and reads each clone's actual price and caps. Defaults are mint price 0 and royalty 500; creators explicitly submit their chosen values. Use integer wei arithmetic for both fee formulas.
3. Before collection minting, its owner pins the ordered art/metadata on IPFS, publishes the commitment algorithm/encoding and ordered input manifest, calls `setProvenanceHash(bytes32)` with that manifest's digest, and optionally calls `setUnrevealedURI(string)` with the pinned placeholder CID.
4. When ready to reveal, its owner publishes the off-chain seed and mapping, calls `setRevealSeed(bytes32)` once and `setBaseURI(string)` with the pinned metadata directory. IDs must match the files `1.json` through `maxSupply.json`. Owners verify the content and seed before calling `freezeMetadata()` permanently. Minting is available immediately after creation; an owner needing setup time must pause promptly or create-and-pause atomically through its own wallet contract.
5. Platform, reserve and creator wallets must continue accepting native ETH. Collection owners and the factory pauser manage their respective pause controls. Ownership handovers and renunciation are deliberate operations, never implicit launch defaults.

See [the ABI integration guide](docs/ABI.md), [generated ABI arrays](docs/abi/), and [builder verification notes](docs/VERIFICATION.md). These tests do not replace the separately assigned independent adversarial review.
