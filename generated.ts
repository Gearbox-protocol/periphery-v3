//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// IPriceFeedCompressor
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

export const iPriceFeedCompressorAbi = [
  {
    type: 'function',
    inputs: [],
    name: 'contractType',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'priceOracle', internalType: 'address', type: 'address' },
      { name: 'tokens', internalType: 'address[]', type: 'address[]' },
    ],
    name: 'getPriceFeeds',
    outputs: [
      {
        name: 'priceFeedMap',
        internalType: 'struct PriceFeedMapEntry[]',
        type: 'tuple[]',
        components: [
          { name: 'token', internalType: 'address', type: 'address' },
          { name: 'reserve', internalType: 'bool', type: 'bool' },
          { name: 'priceFeed', internalType: 'address', type: 'address' },
          { name: 'stalenessPeriod', internalType: 'uint32', type: 'uint32' },
        ],
      },
      {
        name: 'priceFeedTree',
        internalType: 'struct PriceFeedTreeNode[]',
        type: 'tuple[]',
        components: [
          {
            name: 'baseParams',
            internalType: 'struct BaseParams',
            type: 'tuple',
            components: [
              { name: 'addr', internalType: 'address', type: 'address' },
              { name: 'version', internalType: 'uint256', type: 'uint256' },
              {
                name: 'contractType',
                internalType: 'bytes32',
                type: 'bytes32',
              },
              {
                name: 'serializedParams',
                internalType: 'bytes',
                type: 'bytes',
              },
            ],
          },
          { name: 'decimals', internalType: 'uint8', type: 'uint8' },
          { name: 'skipCheck', internalType: 'bool', type: 'bool' },
          { name: 'updatable', internalType: 'bool', type: 'bool' },
          {
            name: 'underlyingFeeds',
            internalType: 'address[]',
            type: 'address[]',
          },
          {
            name: 'underlyingStalenessPeriods',
            internalType: 'uint32[]',
            type: 'uint32[]',
          },
          {
            name: 'answer',
            internalType: 'struct PriceFeedAnswer',
            type: 'tuple',
            components: [
              { name: 'price', internalType: 'int256', type: 'int256' },
              { name: 'updatedAt', internalType: 'uint256', type: 'uint256' },
              { name: 'success', internalType: 'bool', type: 'bool' },
            ],
          },
        ],
      },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [{ name: 'priceOracle', internalType: 'address', type: 'address' }],
    name: 'getPriceFeeds',
    outputs: [
      {
        name: 'priceFeedMap',
        internalType: 'struct PriceFeedMapEntry[]',
        type: 'tuple[]',
        components: [
          { name: 'token', internalType: 'address', type: 'address' },
          { name: 'reserve', internalType: 'bool', type: 'bool' },
          { name: 'priceFeed', internalType: 'address', type: 'address' },
          { name: 'stalenessPeriod', internalType: 'uint32', type: 'uint32' },
        ],
      },
      {
        name: 'priceFeedTree',
        internalType: 'struct PriceFeedTreeNode[]',
        type: 'tuple[]',
        components: [
          {
            name: 'baseParams',
            internalType: 'struct BaseParams',
            type: 'tuple',
            components: [
              { name: 'addr', internalType: 'address', type: 'address' },
              { name: 'version', internalType: 'uint256', type: 'uint256' },
              {
                name: 'contractType',
                internalType: 'bytes32',
                type: 'bytes32',
              },
              {
                name: 'serializedParams',
                internalType: 'bytes',
                type: 'bytes',
              },
            ],
          },
          { name: 'decimals', internalType: 'uint8', type: 'uint8' },
          { name: 'skipCheck', internalType: 'bool', type: 'bool' },
          { name: 'updatable', internalType: 'bool', type: 'bool' },
          {
            name: 'underlyingFeeds',
            internalType: 'address[]',
            type: 'address[]',
          },
          {
            name: 'underlyingStalenessPeriods',
            internalType: 'uint32[]',
            type: 'uint32[]',
          },
          {
            name: 'answer',
            internalType: 'struct PriceFeedAnswer',
            type: 'tuple',
            components: [
              { name: 'price', internalType: 'int256', type: 'int256' },
              { name: 'updatedAt', internalType: 'uint256', type: 'uint256' },
              { name: 'success', internalType: 'bool', type: 'bool' },
            ],
          },
        ],
      },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'priceFeeds', internalType: 'address[]', type: 'address[]' },
    ],
    name: 'loadPriceFeedTree',
    outputs: [
      {
        name: 'priceFeedTree',
        internalType: 'struct PriceFeedTreeNode[]',
        type: 'tuple[]',
        components: [
          {
            name: 'baseParams',
            internalType: 'struct BaseParams',
            type: 'tuple',
            components: [
              { name: 'addr', internalType: 'address', type: 'address' },
              { name: 'version', internalType: 'uint256', type: 'uint256' },
              {
                name: 'contractType',
                internalType: 'bytes32',
                type: 'bytes32',
              },
              {
                name: 'serializedParams',
                internalType: 'bytes',
                type: 'bytes',
              },
            ],
          },
          { name: 'decimals', internalType: 'uint8', type: 'uint8' },
          { name: 'skipCheck', internalType: 'bool', type: 'bool' },
          { name: 'updatable', internalType: 'bool', type: 'bool' },
          {
            name: 'underlyingFeeds',
            internalType: 'address[]',
            type: 'address[]',
          },
          {
            name: 'underlyingStalenessPeriods',
            internalType: 'uint32[]',
            type: 'uint32[]',
          },
          {
            name: 'answer',
            internalType: 'struct PriceFeedAnswer',
            type: 'tuple',
            components: [
              { name: 'price', internalType: 'int256', type: 'int256' },
              { name: 'updatedAt', internalType: 'uint256', type: 'uint256' },
              { name: 'success', internalType: 'bool', type: 'bool' },
            ],
          },
        ],
      },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'version',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'contractType',
        internalType: 'bytes32',
        type: 'bytes32',
        indexed: true,
      },
      {
        name: 'serializer',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
    ],
    name: 'SetSerializer',
  },
]

