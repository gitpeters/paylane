package com.paylane;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

@SpringBootApplication
@ConfigurationPropertiesScan
public class PaylaneApplication {

	public static void main(String[] args) {
		SpringApplication.run(PaylaneApplication.class, args);
	}

}
