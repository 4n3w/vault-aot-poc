// Seeds MongoDB for 05/06 (run with mongosh as root; k3d.sh pipes it in). Idempotent.
//   SEED_DOCS:        reference_items documents to load (default 5000)
//   STATIC_PASSWORD:  password of the static user whose credentials go into Vault KV
const docs = Number(process.env.SEED_DOCS || 5000);
const startup = db.getSiblingDB('startup');

if (startup.reference_items.countDocuments() !== docs) {
  startup.reference_items.drop();   // also drops the indexes, so the apps create them
  const batch = [];
  for (let i = 0; i < docs; i++) {
    batch.push({ code: `item-${i}`, category: `category-${i % 20}`, region: `region-${i % 7}`,
                 name: `Reference item ${i}` });
  }
  startup.reference_items.insertMany(batch);
}

// Static user for the KV-creds variants. Dynamic-creds users are created by Vault's database engine.
const admin = db.getSiblingDB('admin');
const roles = [{ role: 'readWrite', db: 'startup' }];
if (admin.getUser('startup-static')) {
  admin.updateUser('startup-static', { pwd: process.env.STATIC_PASSWORD, roles });
} else {
  admin.createUser({ user: 'startup-static', pwd: process.env.STATIC_PASSWORD, roles });
}
print(`mongo seeded: ${startup.reference_items.countDocuments()} reference_items`);
