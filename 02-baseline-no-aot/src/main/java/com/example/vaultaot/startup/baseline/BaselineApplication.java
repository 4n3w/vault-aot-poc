package com.example.vaultaot.startup.baseline;

import java.util.Map;

import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ApplicationRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** Baseline: no sidecar, no injection - Spring Cloud Vault fetches secrets from Vault itself. AOT off by default. */
@SpringBootApplication
@RestController
public class BaselineApplication {

    private static final Log logger = LogFactory.getLog(BaselineApplication.class);

    // No default: startup fails if the secret didn't arrive.
    private final String dbPassword;

    BaselineApplication(@Value("${db.password}") String dbPassword) {
        this.dbPassword = dbPassword;
    }

    public static void main(String[] args) {
        SpringApplication.run(BaselineApplication.class, args);
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
