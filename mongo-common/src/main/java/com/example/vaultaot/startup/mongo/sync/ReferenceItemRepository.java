package com.example.vaultaot.startup.mongo.sync;

import com.example.vaultaot.startup.mongo.ReferenceItem;

import org.springframework.data.mongodb.repository.MongoRepository;

public interface ReferenceItemRepository extends MongoRepository<ReferenceItem, String> {

    long countByCategory(String category);
}
