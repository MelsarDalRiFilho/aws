// JSON Schema do payload do dispositivo (após decifrar).
const flag = { type: 'integer', enum: [0, 1] };

module.exports = {
  type: 'object',
  required: ['deviceId', 'timestamp', 'type', 'nonce'],
  additionalProperties: false,
  properties: {
    deviceId: { type: 'string', pattern: '^[A-Za-z0-9_-]{1,64}$' },
    nonce: { type: 'string', pattern: '^[A-Za-z0-9_-]{16,64}$' },
    timestamp: {
      type: 'string',
      pattern: '^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d{1,3})?(Z|[+-]\\d{2}:\\d{2})$',
    },
    type: { type: 'string', enum: ['telemetry'] },
    data: {
      type: 'object',
      additionalProperties: false,
      properties: {
        lat: { type: 'number', minimum: -90, maximum: 90 },
        lon: { type: 'number', minimum: -180, maximum: 180 },
        battery: { type: 'integer', minimum: 0, maximum: 100 },
        Tamper: flag,
        Motion: flag,
        Impact: flag,
        InternalMoisture: flag,
        MetallicMaterial: flag,
        Jamming: flag,
      },
    },
  },
};
