package com.example.vaultaot.startup.mongo.files;

import java.util.Map;

import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;

import com.example.vaultaot.startup.mongo.sync.SyncMongoConfiguration;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ApplicationRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** 06 optimized + MongoDB: secrets (db.password and Mongo credentials) arrive as files - from VSO or a Vault Agent init container. */
@SpringBootApplication
@Import(SyncMongoConfiguration.class)
@RestController
public class MongoFilesApplication {

    private static final Log logger = LogFactory.getLog(MongoFilesApplication.class);

    // No default: startup fails if the secret didn't arrive.
    private final String dbPassword;

    MongoFilesApplication(@Value("${db.password}") String dbPassword) {
        this.dbPassword = dbPassword;
    }

    public static void main(String[] args) {
        SpringApplication.run(MongoFilesApplication.class, args);
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
