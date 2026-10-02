package com.example.vaultaot.startup.mongo.reactive;

import com.example.vaultaot.startup.mongo.MongoInit;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.mongodb.core.ReactiveMongoTemplate;

@Configuration(proxyBeanMethods = false)
public class ReactiveMongoConfiguration {

    @Bean
    MongoInit mongoInit(@Value("${mongo.init:reactive}") String mode, @Value("${mongo.creds:kv}") String creds) {
        return new MongoInit(mode, creds);
    }

    @Bean
    ReactiveReferenceDataCache reactiveReferenceDataCache(ReactiveMongoTemplate template, MongoInit mongoInit) {
        return new ReactiveReferenceDataCache(template, mongoInit);
    }

    @Bean
    ReactiveItemsController reactiveItemsController(ReactiveMongoTemplate template, ReactiveReferenceDataCache cache) {
        return new ReactiveItemsController(template, cache);
    }
}
