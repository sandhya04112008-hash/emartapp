package com.springwork.bookwork.controller;

import com.springwork.bookwork.model.Book;
import com.springwork.bookwork.repository.BookRepository;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@CrossOrigin(origins = "*", allowedHeaders = "*", maxAge = 3600)
@RestController
@RequestMapping("/api/shop")
public class ShopController {
    
    @Autowired
    private BookRepository bookRepository;
    
    @GetMapping("/info")
    public ResponseEntity<?> getShopInfo() {
        try {
            List<Book> books = bookRepository.findAll();
            return ResponseEntity.ok(new ApiResponse(true, "Shop information retrieved", books));
        } catch (Exception e) {
            return ResponseEntity.status(500).body(new ApiResponse(false, "Failed to retrieve information", null));
        }
    }
    
    static class ApiResponse {
        private boolean success;
        private String message;
        private Object data;
        
        public ApiResponse(boolean success, String message, Object data) {
            this.success = success;
            this.message = message;
            this.data = data;
        }
        
        public boolean isSuccess() { return success; }
        public String getMessage() { return message; }
        public Object getData() { return data; }
    }
}
