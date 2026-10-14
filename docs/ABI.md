# ABI and integration guide

Canonical machine-readable ABI arrays:

- [LoomCollection.json](abi/LoomCollection.json)
- [LoomFactory.json](abi/LoomFactory.json)
- [LaunchToken.json](abi/LaunchToken.json)

Generated from the Solidity 0.8.26 build artifacts with `python3 scripts/export_abi.py`. Run `--check` after `forge build` to detect stale exports. Amounts are uint256 integer **wei**, quantities and IDs are uint256, and royalty basis points are uint96. All ordinary state-changing functions below are nonpayable unless marked payable.

## LoomFactory

Constructor: `constructor(address implementation_, address platform, address pauser_)`.

| Function | Access / behavior |
| --- | --- |
| `createCollection(string name, string symbol, uint256 maxSupply, uint256 mintPriceWei, uint256 maxPerWallet, address creator, uint96 royaltyBps) payable returns (address collection)` | Anyone while unpaused; exactly `CREATE_FEE`; atomic clone creation and initialization; caller becomes owner |
| `implementation()`, `PLATFORM()`, `pauser()` | Immutable addresses |
| `CREATE_FEE()` | `2000000000000000` wei |
| `collectionCount()` | Number of successfully created collections |
| `collections(uint256 index)` | Address at zero-based creation index; out-of-bounds access reverts |
| `isCollection(address collection)` | Whether this factory registered the address |
| `getCollections(uint256 offset, uint256 limit)` | Address array in creation order; limit at most `MAX_PAGE_SIZE()` (100); offset past end returns empty; zero limit returns empty |
| `pause()`, `unpause()` | Immutable pauser only; affects new collection creation |
| `paused()` | Creation pause state |

`CollectionCreated(address indexed collection, address indexed owner, string name, uint256 maxSupply)` is the creation receipt. Read the clone's remaining parameters directly; the event's owner is its **initial** owner, not necessarily its current owner after a handover. The standard OpenZeppelin `Paused(address)` and `Unpaused(address)` events record pause changes.

Custom factory errors include `ZeroAddress`, `UnauthorizedPauser`, `IncorrectCreateFee(expected,actual)`, `InvalidImplementation`, `PlatformMismatch`, `ETHTransferFailed(recipient)`, and `PageTooLarge`. Creation may also bubble collection initialization errors. Pausing, reentrancy and clone-creation errors are in the generated ABI.

## LoomCollection

Implementation constructor: `constructor(address platform, address reserve)`. Clones use:

```solidity
initialize(
    string name_,
    string symbol_,
    uint256 maxSupply_,
    uint256 mintPriceWei_,
    uint256 maxPerWallet_,
    address creator_,
    uint96 royaltyBps_,
    address owner_
)
```

`initialize` is public, nonpayable, and usable once on a fresh clone; it always reverts on the implementation and on an initialized clone. Use the factory, which initializes atomically. Never send an initialization transaction to an already created factory collection.

| Function | Access / behavior |
| --- | --- |
| `mint(uint256 quantity) payable` | Mint to caller; positive quantity; lifetime public wallet cap, supply cap and exact payment |
| `reserveMint(uint256 quantity) payable` | Owner only; positive quantity; lifetime `floor(maxSupply/100)` reserve limit plus supply cap; same payment formula |
| `pause()`, `unpause()` | Owner only; both mint paths; transfers and metadata administration remain available |
| `setProvenanceHash(bytes32 hash)` | Owner only; once, supply zero, metadata not frozen |
| `setRevealSeed(bytes32 seed)` | Owner only; once, metadata not frozen; records an off-chain seed |
| `setBaseURI(string uri)` | Owner only; metadata not frozen |
| `setUnrevealedURI(string uri)` | Owner only; metadata not frozen |
| `freezeMetadata()` | Owner only; irreversible; all four metadata setters become unavailable |
| `tokenURI(uint256 tokenId)` | Existing token only; base URI + decimal ID + `.json`, or the unrevealed URI if base is empty |
| `royaltyInfo(uint256 tokenId, uint256 salePrice)` | Returns `(address creator, uint256 royaltyAmount)`; fixed rate, rounded down; accepts any ID |
| `transferOwnership(address newOwner)` | Owner proposes new owner; zero cancels a pending handover |
| `acceptOwnership()` | Pending owner accepts |
| `renounceOwnership()` | Owner relinquishes all owner powers permanently; pending owner cleared |

Payment for **either mint path**:

```text
quantity * (collection.mintPriceWei() + collection.PLATFORM_FEE())
```

Use big integers, not floating-point ETH calculations. Sending excess ETH does not trigger a refund; it reverts. Mints to contracts require `onERC721Received`. All three fee recipients must accept native ETH. The collection/factory have no plain-ETH receive entry point.

Configuration and state getters:

| Getters | Meaning |
| --- | --- |
| `name()`, `symbol()` | ERC-721 collection labels |
| `owner()`, `pendingOwner()` | Current/proposed collection administrators |
| `creator()`, `royaltyBps()` | Fixed mint proceeds and royalty recipient, and royalty rate |
| `maxSupply()`, `mintPriceWei()`, `maxPerWallet()` | Fixed mint terms |
| `PLATFORM()`, `RESERVE()` | Shared implementation immutables |
| `PLATFORM_FEE()` | 500000000000000 wei per token |
| `CREATOR_FEE_SHARE()`, `PLATFORM_FEE_SHARE()`, `RESERVE_FEE_SHARE()` | 200000000000000, 200000000000000, 100000000000000 wei per token, respectively |
| `MAX_ROYALTY_BPS()`, `RESERVE_SUPPLY_DENOMINATOR()` | 1000 basis points and divisor 100 |
| `totalSupply()`, `reserveMinted()` | All minted tokens and lifetime owner reserve usage |
| `mintedPerWallet(address wallet)` | Lifetime public mints; unaffected by transfers |
| `baseURI()`, `unrevealedURI()` | Current URI prefixes/content references |
| `provenanceHash()`, `provenanceSet()` | Commitment and independent once-set flag |
| `revealSeed()`, `revealSeedSet()` | Recorded seed and independent once-set flag |
| `metadataFrozen()`, `paused()` | Metadata immutability and mint pause flags |

The standard `balanceOf`, `ownerOf`, `approve`, `getApproved`, `setApprovalForAll`, `isApprovedForAll`, `transferFrom`, both `safeTransferFrom` overloads and `supportsInterface` are available. ERC-721 Enumerable is not implemented. To display a wallet's tokens, index `Transfer` logs, handle chain reorganizations, and confirm ownership. IDs after a successful mint are sequential starting at 1.

| Event | Interpretation |
| --- | --- |
| `Minted(address indexed minter, uint256 indexed firstTokenId, uint256 quantity)` | Emitted for both public and reserve mints; covers IDs `[firstTokenId, firstTokenId + quantity - 1]` |
| `ReserveMinted(address indexed owner, uint256 indexed firstTokenId, uint256 quantity)` | Additional event distinguishing reserve mints |
| `FeesDistributed(uint256 creatorAmount, uint256 platformAmount, uint256 reserveAmount)` | Total batch payouts; creator amount includes mint price and fee share |
| `ProvenanceSet(bytes32 provenanceHash)` | One-time provenance recorded |
| `Revealed(bytes32 revealSeed)` | Seed recorded; URI changes are separate |
| `MetadataFrozen()` | All metadata setters permanently locked |
| `BaseURISet(string baseURI)`, `UnrevealedURISet(string unrevealedURI)` | URI updates |

Standard `Transfer`, `Approval`, `ApprovalForAll`, `OwnershipTransferStarted`, `OwnershipTransferred`, `Paused`, `Unpaused`, and `Initialized` events are included in the ABI. Events are reverted along with a failed transaction. `Minted` is emitted before receiver hooks and `FeesDistributed` before the ETH calls; only successful receipts establish completion. Callback transfers can change token ownership during a mint, so use `Transfer` logs/current `ownerOf` for current ownership.

Collection validation errors are `ZeroAddress`, `EmptyNameOrSymbol`, `InvalidSupplyOrWalletCap`, `InvalidMintPrice`, and `RoyaltyTooHigh`. Mint errors are `ZeroQuantity`, `SupplyCapExceeded`, `WalletCapExceeded`, `ReserveCapExceeded`, `IncorrectPayment(expected,actual)`, and `ETHTransferFailed(recipient)`. Metadata errors are `MetadataIsFrozen`, `ProvenanceAlreadySet`, `MintingAlreadyStarted`, and `RevealSeedAlreadySet`. OpenZeppelin initialization, ownership, pause, ERC-721 and reentrancy errors are also exported. uint256 overflow of a batch price raises Solidity's arithmetic panic.

## LaunchToken

Constructor has no parameters. Standard ERC-20 functions and events are in its ABI: `name`, `symbol`, `decimals`, `totalSupply`, `balanceOf`, `allowance`, `approve`, `transfer`, `transferFrom`, `Transfer`, and `Approval`. It supplies no privileged or post-construction mint interface. The application contracts do not require token approvals or LOOM balances.
