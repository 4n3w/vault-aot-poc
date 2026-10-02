package com.example.vaultaot.startup.mongo.sync;

import com.example.vaultaot.startup.mongo.MongoInit;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.mongodb.core.MongoTemplate;
import org.springframework.data.mongodb.repository.config.EnableMongoRepositories;

/** Imported by the sync (blocking driver) apps in 05 and 06. */
@Configuration(proxyBeanMethods = false)
@EnableMongoRepositories(basePackageClasses = ReferenceItemRepository.class)
public class SyncMongoConfiguration {

    @Bean
    MongoInit mongoInit(@Value("${mongo.init:blocking}") String mode, @Value("${mongo.creds:kv}") String creds) {
        return new MongoInit(mode, creds);
    }

    @Bean
    ReferenceDataCache referenceDataCache(MongoTemplate template, ReferenceItemRepository repository,
            MongoInit mongoInit) {
        return new ReferenceDataCache(template, repository, mongoInit);
    }

    @Bean
    ItemsController itemsController(ReferenceItemRepository repository, ReferenceDataCache cache) {
        return new ItemsController(repository, cache);
    }
}
