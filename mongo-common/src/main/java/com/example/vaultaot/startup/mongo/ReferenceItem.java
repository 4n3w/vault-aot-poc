package com.example.vaultaot.startup.mongo;

import org.springframework.data.annotation.Id;
import org.springframework.data.mongodb.core.index.Indexed;
import org.springframework.data.mongodb.core.mapping.Document;

/** Reference data the app caches at startup; k3d.sh seeds MONGO_SEED_DOCS of them. */
@Document("reference_items")
public record ReferenceItem(@Id String id, @Indexed(unique = true) String code, @Indexed String category,
        @Indexed String region, String name) {
}
