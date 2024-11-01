pragma solidity >=0.8.25;

/*******************************************************************************
 *
 * Copyright (c) 2024 Ava's DAO.
 * SPDX-License-Identifier: MIT
 *
 * Native Miner - Crypto Token Mining Contract (for a "native" L1 coin)
 *
 *                 Native Miner has been optimized for native minting from
 *                 an Avalanche L1 blockchain.
 *
 *                 Learn more below:
 *
 *                 Official : https://minado.io/contracts
 *                 Ethereum : https://eips.ethereum.org/EIPS/eip-918
 *                 Github   : https://github.com/ethereum/EIPs/pull/918
 *                 Reddit   : https://www.reddit.com/r/Tokenmining
 *
 * Version 24.10.30
 *
 * Web    : https://avasdao.org
 * Email  : support@avasdao.org
 */

/*******************************************************************************
 *
 * Owned contract
 */
abstract contract Owned {
    address public owner;
    address public newOwner;
    event OwnershipTransferred(address indexed _from, address indexed _to);

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner {
        require(msg.sender == owner);
        _;
    }

    function transferOwnership(address _newOwner) public onlyOwner {
        newOwner = _newOwner;
    }

    function acceptOwnership() public {
        require(msg.sender == newOwner);
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
        newOwner = address(0);
    }
}

/*******************************************************************************
 *
 * Eternal Database Interface
 */
interface IEternalDb {
    /* Interface getters. */
    function getAddress(bytes32 _key) external view returns (address);
    function getBool(bytes32 _key)    external view returns (bool);
    function getBytes(bytes32 _key)   external view returns (bytes calldata);
    function getInt(bytes32 _key)     external view returns (int);
    function getString(bytes32 _key)  external view returns (string calldata);
    function getUint(bytes32 _key)    external view returns (uint);

    /* Interface setters. */
    function setAddress(bytes32 _key, address _value) external;
    function setBool(bytes32 _key, bool _value) external;
    function setBytes(bytes32 _key, bytes calldata _value) external;
    function setInt(bytes32 _key, int _value) external;
    function setString(bytes32 _key, string calldata _value) external;
    function setUint(bytes32 _key, uint _value) external;

    /* Interface deletes. */
    function deleteAddress(bytes32 _key) external;
    function deleteBool(bytes32 _key) external;
    function deleteBytes(bytes32 _key) external;
    function deleteInt(bytes32 _key) external;
    function deleteString(bytes32 _key) external;
    function deleteUint(bytes32 _key) external;
}

/*******************************************************************************
 *
 * Avalanche Subnet-EVM Native Miner Interface
 */
abstract contract INativeMinter {
    function mintNativeCoin(address addr, uint256 amount) virtual external;
    event NativeCoinMinted(address indexed sender, address indexed recipient, uint256 amount);
}


/*******************************************************************************
 *
 * @notice Native Miner - Token Mining Contract
 *
 * @dev This is a multi-token mining contract, which manages the proof-of-work
 *      verifications before authorizing the movement of tokens from the
 *      Infinity Pool and Infinity Well.
 */
contract NativeMiner is Owned {
    /* Initialize predecessor contract. */
    address payable private _predecessor;

    /* Initialize successor contract. */
    address payable private _successor;

    /* Initialize revision number. */
    uint private _revision;

    /* Initialize Eternal database contract. */
    IEternalDb private _eternalDb;

    /* Initialize Native Minter (pre-compiled) contract. */
    INativeMinter private _nativeMinter;

    /**
     * Set Namespace
     *
     * Provides a "unique" name for generating "unique" data identifiers,
     * most commonly used as database "key-value" keys.
     *
     * NOTE: Use of `namespace` is REQUIRED when generating ANY & ALL
     *       EternalDb keys; in order to prevent ANY accidental or
     *       malicious SQL-injection vulnerabilities / attacks.
     */
    string private _namespace = 'native.miner';

    /**
     * Maximum Target
     *
     * A big number used for difficulty targeting.
     *
     * NOTE: Bitcoin uses `2**224`.
     */
    uint private _MAXIMUM_TARGET = 2**234;

    /**
     * Minimum Target
     *
     * Minimum number used for difficulty targeting.
     */
    uint private _MINIMUM_TARGET = 2**16;

    /**
     * Set basis-point multiplier.
     *
     * NOTE: Used for (integer-based) fractional calculations.
     */
    // uint private _BP_MUL = 10000;

    /* Set Coin decimals. */
    uint private _COIN_DECIMALS = 18;

    /* Set single Coin. */
    // uint private _SINGLE_COIN = 1 * 10**_COIN_DECIMALS;

    /**
     * (Ethereum) Blocks Per Forge
     *
     * NOTE: Ethereum blocks take approx 15 seconds each.
     *       1,000 blocks takes approx 4 hours.
     */
    // uint private _BLOCKS_PER_COIN_FORGE = 1000;

    /**
     * (Ethereum) Blocks Per Generation
     *
     * NOTE: We mirror the Bitcoin POW mining algorithm.
     *       We want miners to spend 10 minutes to mine each 'block'.
     *       (about 40 Ethereum blocks for every 1 Bitcoin block)
     */
    // uint BLOCKS_PER_GENERATION = 40; // Mainnet & Ropsten
    uint BLOCKS_PER_GENERATION = 120; // Kovan

    /**
     * (Mint) Generations Per Re-adjustment
     *
     * By default, we automatically trigger a difficulty adjustment
     * after 144 generations / mints (approx 24 hours).
     *
     * Frequent adjustments are especially important with low-liquidity
     * tokens, which are more susceptible to mining manipulation.
     *
     * For additional control, token providers retain the ability to trigger
     * a difficulty re-calculation at any time.
     *
     * NOTE: Bitcoin re-adjusts its difficulty every 2,016 generations,
     *       which occurs approx. every 14 days.
     */
    uint private _DEFAULT_GENERATIONS_PER_ADJUSTMENT = 144; // approx. 24hrs

    event NativeMint(
        address indexed from,
        uint rewardAmount,
        uint epochCount,
        uint difficulty,
        bytes32 newChallenge
    );

    // event ReCalculate(
    //     address token,
    //     uint newDifficulty
    // );

    /* Constructor. */
    constructor() {
        /* Initialize EternalDb (data storage) contract. */
        // NOTE We hard-code the address here, since it should never change.
        _eternalDb = IEternalDb(0x0000000000000000000000000000000000000000); // AVA'S DAO

        /* Initialize (aname) hash. */
        bytes32 hash = keccak256(abi.encodePacked('aname.', _namespace));

        /* Set predecessor address. */
        _predecessor = payable(_eternalDb.getAddress(hash));

        /* Verify predecessor address. */
        if (_predecessor != payable(0x0)) {
            /* Retrieve the last revision number (if available). */
            uint lastRevision = NativeMiner(_predecessor).getRevision();

            /* Set (current) revision number. */
            _revision = lastRevision + 1;
        }

        /* Set native minter (pre-compile) address. */
        _nativeMinter = INativeMinter(0x0200000000000000000000000000000000000001);
    }

    /**
     * @dev Only allow access to an authorized administrator.
     */
    modifier onlyByAuth() {
        /* Verify write access is only permitted to authorized accounts. */
        require(_eternalDb.getBool(keccak256(
            abi.encodePacked(msg.sender, '.has.auth.for.', _namespace))) == true);

        _;      // function code is inserted here
    }

    /**
     * THIS CONTRACT DOES NOT ACCEPT DIRECT ETHER
     */
    receive() external payable {
        /* Cancel this transaction. */
        revert('Oops! Direct payments are NOT permitted here.');
    }


    /***************************************************************************
     *
     * ACTIONS
     *
     */

    /**
     * Initialize Contract
     */
    function init() external onlyByAuth returns (bool success) {
        /* Set hash. */
        bytes32 hash = keccak256(abi.encodePacked(
            _namespace, '.last.adjustment'
        ));

        /* Set current adjustment time in EternalDb. */
        _eternalDb.setUint(hash, block.number);

        /* Set hash. */
        hash = keccak256(abi.encodePacked(
            _namespace, '.generations.per.adjustment'
        ));

        /* Set value in EternalDb. */
        _eternalDb.setUint(hash, _DEFAULT_GENERATIONS_PER_ADJUSTMENT);

        /* Set hash. */
        hash = keccak256(abi.encodePacked(
            _namespace, '.challenge'
        ));

        /* Set current adjustment time in EternalDb. */
        _eternalDb.setBytes(
            hash,
            _bytes32ToBytes(blockhash(block.number - 1))
        );

        /* Set (initial) mining target. */
        // NOTE: This is the default difficulty of 1.
        _setMiningTarget(_MAXIMUM_TARGET);

        return true;
    }

    /**
     * Mint
     */
    function mint(
        bytes32 _digest,
        uint _nonce
    ) public returns (bool success) {
        /* Retrieve the current challenge. */
        uint challenge = getChallenge();

        /* Get mint digest. */
        bytes32 digest = getMintDigest(
            challenge,
            msg.sender,
            _nonce
        );

        /* The challenge digest must match the expected. */
        if (digest != _digest) {
            revert('Oops! That solution is NOT valid.');
        }

        /* The digest must be smaller than the target. */
        if (uint(digest) > getTarget()) {
            revert('Oops! That solution is NOT valid.');
        }

        /* Set hash. */
        bytes32 hash = keccak256(abi.encodePacked(
            _namespace, '.',
            digest,
            '.solution'
        ));

        /* Retrieve value from EternalDb. */
        uint solution = _eternalDb.getUint(hash);

        /* Validate solution. */
        if (solution != 0x0) {
            revert('Oops! That solution is a DUPLICATE.');
        }

        /* Save this digest to 'solved' solutions. */
        _eternalDb.setUint(hash, uint(digest));

        /* Set hash. */
        hash = keccak256(abi.encodePacked(
            _namespace, '.generation'
        ));

        /* Retrieve value from EternalDb. */
        uint generation = _eternalDb.getUint(hash);

        /* Increment the generation. */
        generation = (generation + 1);

        /* Increment the generation count by 1. */
        _eternalDb.setUint(hash, generation);

        /* Set hash. */
        hash = keccak256(abi.encodePacked(
            _namespace, '.generations.per.adjustment'
        ));

        /* Retrieve value from EternalDb. */
        uint genPerAdjustment = _eternalDb.getUint(hash);

        // every so often, readjust difficulty. Dont readjust when deploying
        if (generation % genPerAdjustment == 0) {
            _reAdjustDifficulty();
        }

        /* Set hash. */
        hash = keccak256(abi.encodePacked(
            _namespace, '.challenge'
        ));

        /**
         * Make the latest ethereum block hash a part of the next challenge
         * for PoW to prevent pre-mining future blocks. Do this last,
         * since this is a protection mechanism in the mint() function.
         */
        _eternalDb.setBytes(
            hash,
            _bytes32ToBytes(blockhash(block.number - 1))
        );

        /* Retrieve mining reward. */
        // FIXME Add support for percentage reward.
        uint rewardAmount = getMintFixed();

        /* Retrieve mining tribute. */
        // FIXME Add support for percentage reward.
        uint miningAmount = uint((rewardAmount * 92) / 100); // 8.00%

        /* Retrieve mining tribute. */
        // FIXME Add support for percentage reward.
        uint tributeAmount = (rewardAmount - miningAmount);

        /* Transfer (token) reward to minter. */
        _nativeMinter.mintNativeCoin(msg.sender, rewardAmount);

        /* Set hash. */
        hash = keccak256('aname.mining.tributes');

        /* Retrieve tribute address. */
        address tributeAddress = _eternalDb.getAddress(hash);

        /* Transfer (token) Tribute platform treasury. */
        _nativeMinter.mintNativeCoin(tributeAddress, tributeAmount);

        /* Emit log info. */
        emit NativeMint(
            msg.sender,
            rewardAmount,
            generation,
            getDifficulty(),
            blockhash(block.number - 1) // next target
        );

        /* Return success. */
        return true;
    }

    /**
     * Test Mint Solution
     */
    function testMint(
        bytes32 _digest,
        uint _challenge,
        uint _nonce,
        uint _target
    ) public view returns (bool success) {
        /* Retrieve digest. */
        bytes32 digest = getMintDigest(
            _challenge,
            msg.sender,
            _nonce
        );

        /* Validate digest. */
        // NOTE: Cast type to 256-bit integer
        if (uint(getTarget()) > _target) {
            /* Set flag. */
            success = false;
        } else {
            /* Verify success. */
            success = (digest == _digest);
        }
    }

    /**
     * Test Mint Solution
     */
    function testMint(
        bytes32 _digest,
        uint _challenge,
        address _minter,
        uint _nonce,
        uint _target
    ) public pure returns (bool success) {
        /* Retrieve digest. */
        bytes32 digest = getMintDigest(
            _challenge,
            _minter,
            _nonce
        );

        /* Validate digest. */
        // NOTE: Cast type to 256-bit integer
        if (uint(digest) > _target) {
            /* Set flag. */
            success = false;
        } else {
            /* Verify success. */
            success = (digest == _digest);
        }
    }

    /**
     * Re-calculate Difficulty
     *
     * Token owner(s) can "manually" trigger the re-calculation of their token,
     * based on the parameters that have been set.
     *
     * NOTE: This will help deter malicious miners from gaming the difficulty
     *       parameter, to the detriment of the token's community.
     */
    function reCalculateDifficulty() external onlyByAuth returns (bool success) {
        /* Re-adjust difficulty. */
        return _reAdjustDifficulty();
    }

    /**
     * Re-adjust Difficulty
     *
     * Re-adjust the target by 5 percent.
     * (source: https://en.bitcoin.it/wiki/Difficulty#What_is_the_formula_for_difficulty.3F)
     *
     * NOTE: Assume 240 ethereum blocks per hour (approx. 15/sec)
     *
     * NOTE: As of 2017 the bitcoin difficulty was up to 17 zeroes,
     *       it was only 8 in the early days.
     */
    function _reAdjustDifficulty() private returns (bool success) {
        /* Set hash. */
        bytes32 lastAdjustmentHash = keccak256(abi.encodePacked(
            _namespace, '.last.adjustment'
        ));

        /* Retrieve value from EternalDb. */
        uint lastAdjustment = _eternalDb.getUint(lastAdjustmentHash);

        /* Retrieve value from EternalDb. */
        uint blocksSinceLastAdjustment = block.number - lastAdjustment;

        /* Set hash. */
        bytes32 adjustmentHash = keccak256(abi.encodePacked(
            _namespace, '.generations.per.adjustment'
        ));

        /* Retrieve value from EternalDb. */
        uint genPerAdjustment = _eternalDb.getUint(adjustmentHash);

        /* Calculate number of expected blocks per adjustment. */
        uint expectedBlocksPerAdjustment = (genPerAdjustment * BLOCKS_PER_GENERATION);

        /* Retrieve mining target. */
        uint miningTarget = getTarget();

        /* Validate the number of blocks passed; if there were less eth blocks
         * passed in time than expected, then miners are excavating too quickly.
         */
        if (blocksSinceLastAdjustment < expectedBlocksPerAdjustment) {
            // NOTE: This number will be an integer greater than 10000.
            uint excess_block_pct = (
                (expectedBlocksPerAdjustment * 10000) / blocksSinceLastAdjustment);

            /**
             * Excess Block Percentage Extra
             *
             * For example:
             *     If there were 5% more blocks mined than expected, then this is 500.
             *     If there were 25% more blocks mined than expected, then this is 2500.
             */
            uint excess_block_pct_extra = (excess_block_pct - 10000);

            /* Set a maximum difficulty INCREASE of 50%. */
            // NOTE: By default, this is within a 24hr period.
            if (excess_block_pct_extra > 5000) {
                excess_block_pct_extra = 5000;
            }

            /**
             * Reset the Mining Target
             *
             * Calculate the difficulty difference, then SUBTRACT
             * that value from the current difficulty.
             */
            miningTarget = miningTarget - (
                /* Calculate difficulty difference. */
                ((miningTarget * excess_block_pct_extra) / 10000)
            );
        } else {
            // NOTE: This number will be an integer greater than 10000.
            uint shortage_block_pct = (
                (blocksSinceLastAdjustment * 10000) / expectedBlocksPerAdjustment);

            /**
             * Shortage Block Percentage Extra
             *
             * For example:
             *     If it took 5% longer to mine than expected, then this is 500.
             *     If it took 25% longer to mine than expected, then this is 2500.
             */
            uint shortage_block_pct_extra = (shortage_block_pct - 10000);

            // NOTE: There is NO limit on the amount of difficulty DECREASE.

            /**
             * Reset the Mining Target
             *
             * Calculate the difficulty difference, then ADD
             * that value to the current difficulty.
             */
            miningTarget = miningTarget + (
                ((miningTarget * shortage_block_pct_extra) / 10000)
            );
        }

        /* Set current adjustment time in EternalDb. */
        _eternalDb.setUint(lastAdjustmentHash, block.number);

        /* Validate TOO SMALL mining target. */
        // NOTE: This is very difficult to guess.
        if (miningTarget < _MINIMUM_TARGET) {
            miningTarget = _MINIMUM_TARGET;
        }

        /* Validate TOO LARGE mining target. */
        // NOTE: This is very easy to guess.
        if (miningTarget > _MAXIMUM_TARGET) {
            miningTarget = _MAXIMUM_TARGET;
        }

        /* Set mining target. */
        _setMiningTarget(miningTarget);

        /* Return success. */
        return true;
    }


    /***************************************************************************
     *
     * GETTERS
     *
     */

    /**
     * Get Starting Block
     *
     * Starting Blocks
     * ---------------
     *
     * First blocks honoring the start of Miss Piggy's celebration year:
     *     - Mainnet :  7,175,716
     *     - Ropsten :  4,956,268
     *     - Kovan   : 10,283,438
     *
     * NOTE: Pulls value from db `minado.starting.block` using the
     *       respective networks.
     */
    function getStartingBlock() public view returns (uint startingBlock) {
        /* Set hash. */
        bytes32 hash = keccak256(abi.encodePacked(
            _namespace,
            '.starting.block'
        ));

        /* Retrieve value from EternalDb. */
        startingBlock = _eternalDb.getUint(hash);
    }

    /**
     * Get minter's mintng address.
     */
    function getMinter() external view returns (address minter) {
        /* Set hash. */
        bytes32 hash = keccak256(abi.encodePacked(
            _namespace,
            '.minter'
        ));

        /* Retrieve value from EternalDb. */
        minter = _eternalDb.getAddress(hash);
    }

    /**
     * Get generation details.
     */
    function getGeneration() external view returns (
        uint generation,
        uint cycle
    ) {
        /* Set hash. */
        bytes32 hash = keccak256(abi.encodePacked(
            _namespace, '.generation'
        ));

        /* Retrieve value from EternalDb. */
        generation = _eternalDb.getUint(hash);

        /* Set hash. */
        hash = keccak256(abi.encodePacked(
            _namespace, '.generations.per.adjustment'
        ));

        /* Retrieve value from EternalDb. */
        cycle = _eternalDb.getUint(hash);
    }

    /**
     * Get Minting FIXED amount
     */
    function getMintFixed() public view returns (uint amount) {
        /* Set hash. */
        bytes32 hash = keccak256(abi.encodePacked(
            _namespace, '.mint.fixed'
        ));

        /* Retrieve value from EternalDb. */
        amount = _eternalDb.getUint(hash);
    }

    /**
     * Get Minting PERCENTAGE amount
     */
    function getMintPct() public view returns (uint amount) {
        /* Set hash. */
        bytes32 hash = keccak256(abi.encodePacked(
            _namespace, '.mint.pct'
        ));

        /* Retrieve value from EternalDb. */
        amount = _eternalDb.getUint(hash);
    }

    /**
     * Get (Mining) Challenge
     *
     * This is an integer representation of a recent ethereum block hash,
     * used to prevent pre-mining future blocks.
     */
    function getChallenge() public view returns (uint challenge) {
        /* Set hash. */
        bytes32 hash = keccak256(abi.encodePacked(
            _namespace, '.challenge'
        ));

        /* Retrieve value from EternalDb. */
        // NOTE: Convert from bytes to integer.
        challenge = uint(_bytesToBytes32(
            _eternalDb.getBytes(hash)
        ));
    }

    /**
     * Get (Mining) Difficulty
     *
     * The number of zeroes the digest of the PoW solution requires.
     * (auto adjusts)
     */
    function getDifficulty() public view returns (uint difficulty) {
        /* Caclulate difficulty. */
        difficulty = (_MAXIMUM_TARGET / getTarget());
    }

    /**
     * Get (Mining) Target
     */
    function getTarget() public view returns (uint target) {
        /* Set hash. */
        bytes32 hash = keccak256(abi.encodePacked(
            _namespace, '.target'
        ));

        /* Retrieve value from EternalDb. */
        target = _eternalDb.getUint(hash);
    }

    /**
     * Get Mint Digest
     *
     * The PoW must contain work that includes a recent
     * ethereum block hash (challenge hash) and the
     * msg.sender's address to prevent MITM attacks
     */
    function getMintDigest(
        uint _challenge,
        address _minter,
        uint _nonce
    ) public pure returns (bytes32 digest) {
        /* Calculate digest. */
        digest = keccak256(abi.encodePacked(
            _challenge,
            _minter,
            _nonce
        ));
    }

    /**
     * Get Revision (Number)
     */
    function getRevision() public view returns (uint) {
        return _revision;
    }


    /***************************************************************************
     *
     * SETTERS
     *
     */

    /**
     * Set Generations Per (Difficulty) Adjustment
     *
     * Token owner(s) can adjust the number of generations
     * per difficulty re-calculation.
     *
     * NOTE: This will help deter malicious miners from gaming the difficulty
     *       parameter, to the detriment of the token's community.
     */
    function setGenPerAdjustment(
        uint _numBlocks
    ) external onlyByAuth returns (bool success) {
        /* Set hash. */
        bytes32 hash = keccak256(abi.encodePacked(
            _namespace, '.generations.per.adjustment'
        ));

        /* Set value in EternalDb. */
        _eternalDb.setUint(hash, _numBlocks);

        /* Return success. */
        return true;
    }

    /**
     * Set (Fixed) Mint Amount
     */
    function setMintFixed(
        uint _amount
    ) external onlyByAuth returns (bool success) {
        /* Set hash. */
        bytes32 hash = keccak256(abi.encodePacked(
            _namespace, '.mint.fixed'
        ));

        /* Set value in EternalDb. */
        _eternalDb.setUint(hash, _amount);

        /* Return success. */
        return true;
    }

    /**
     * Set (Dynamic) Mint Percentage
     */
    function setMintPct(
        uint _pct
    ) external onlyByAuth returns (bool success) {
        /* Set hash. */
        bytes32 hash = keccak256(abi.encodePacked(
            _namespace, '.mint.pct'
        ));

        /* Set value in EternalDb. */
        _eternalDb.setUint(hash, _pct);

        /* Return success. */
        return true;
    }

    /**
     * Set Token Parent(s)
     *
     * Enables the use of merged mining by specifying (parent) tokens
     * that offer an acceptibly HIGH difficulty for the child's own
     * mining challenge.
     *
     * Parents are saved in priority levels:
     *     1 - Most significant parent
     *     2 - 2nd most significant parent
     *     ...
     *     # - Least significant parent
     */
    function setTokenParents(
        address[] calldata _parents
    ) external onlyByAuth returns (bool success) {
        /* Set hash. */
        bytes32 hash = keccak256(abi.encodePacked(
            _namespace, '.parents'
        ));

        // FIXME How should we store a dynamic amount of parents?
        //       Packed as bytes??

        // FIXME TEMPORARILY LIMITED TO 3
        bytes memory allParents = abi.encodePacked(
            _parents[0],
            _parents[1],
            _parents[2]
        );

        /* Set value in EternalDb. */
        _eternalDb.setBytes(hash, allParents);

        /* Return success. */
        return true;
    }

    /**
     * Set Mining Target
     */
    function _setMiningTarget(
        uint _target
    ) private returns (bool success) {
        /* Set hash. */
        bytes32 hash = keccak256(abi.encodePacked(
            _namespace, '.target'
        ));

        /* Set value in EternalDb. */
        _eternalDb.setUint(hash, _target);

        /* Return success. */
        return true;
    }


    /***************************************************************************
     *
     * INTERFACES
     *
     */

    /**
     * Supports Interface (EIP-165)
     *
     * (see: https://github.com/ethereum/EIPs/blob/master/EIPS/eip-165.md)
     *
     * NOTE: Must support the following conditions:
     *       1. (true) when interfaceID is 0x01ffc9a7 (EIP165 interface)
     *       2. (false) when interfaceID is 0xffffffff
     *       3. (true) for any other interfaceID this contract implements
     *       4. (false) for any other interfaceID
     */
    function supportsInterface(
        bytes4 _interfaceID
    ) external pure returns (bool) {
        /* Initialize constants. */
        bytes4 InvalidId = 0xffffffff;
        bytes4 ERC165Id = 0x01ffc9a7;

        /* Validate condition #2. */
        if (_interfaceID == InvalidId) {
            return false;
        }

        /* Validate condition #1. */
        if (_interfaceID == ERC165Id) {
            return true;
        }

        // TODO Add additional interfaces here.

        /* Return false (for condition #4). */
        return false;
    }

    /***************************************************************************
     *
     * UTILITIES
     *
     */

    /**
     * Bytes-to-Address
     *
     * Converts bytes into type address.
     */
    function _bytesToAddress(
        bytes calldata _address
    ) private pure returns (address) {
        uint160 m = 0;
        uint160 b = 0;

        for (uint8 i = 0; i < 20; i++) {
            m *= 256;
            b = uint160(uint8(_address[i]));
            m += (b);
        }

        return address(m);
    }

    /**
     * Convert Bytes to Bytes32
     */
    function _bytesToBytes32(
        bytes memory _data
    ) private pure returns (bytes32 result) {
        /* Loop through each byte. */
        for (uint i = 0; i < 32; i++) {
            /* Shift bytes onto result. */
            result |= bytes32(_data[i] & 0xFF) >> (i * 8);
        }
    }

    /**
     * Convert Bytes32 to Bytes
     *
     * NOTE: Since solidity v0.4.22, you can use `abi.encodePacked()` for this,
     *       which returns bytes. (https://ethereum.stackexchange.com/a/55963)
     */
    function _bytes32ToBytes(
        bytes32 _data
    ) private pure returns (bytes memory result) {
        /* Pack the data. */
        return abi.encodePacked(_data);
    }
}
