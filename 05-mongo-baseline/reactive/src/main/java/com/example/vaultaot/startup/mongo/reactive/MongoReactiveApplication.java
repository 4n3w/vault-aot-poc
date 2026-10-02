package com.example.vaultaot.startup.mongo.reactive;

import java.util.Map;

import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ApplicationRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** 05 baseline + MongoDB, reactive driver: same secrets as the sync app; Mongo work is a reactive pipeline after ready. */
@SpringBootApplication
@Import(ReactiveMongoConfiguration.class)
@RestController
public class MongoReactiveApplication {

    private static final Log logger = LogFactory.getLog(MongoReactiveApplication.class);

    // No default: startup fails if the secret didn't arrive.
    private final String dbPassword;

    MongoReactiveApplication(@Value("${db.password}") String dbPassword) {
        this.dbPassword = dbPassword;
    }

    public static void main(String[] args) {
        SpringApplication.run(MongoReactiveApplication.class, args);
    }

    @Bean
    ApplicationRunner reportSecret() {
        return args -> logger.info("db.password loaded=" + !dbPassword.isBlank());
    }

    @GetMapping("/")
    Map<String, Boolean> status() {
        return Map.of("dbPasswordLoaded", !dbPassword.isBlank());
    }
}
