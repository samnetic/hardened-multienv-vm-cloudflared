"""
FastAPI Example Application
Production-ready REST API with health checks and security best practices.
"""

import os
import logging
from typing import List, Optional
from datetime import datetime

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# Configure logging
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

# Application metadata
app = FastAPI(
    title=os.getenv("APP_NAME", "FastAPI Example"),
    description="Production-ready FastAPI application template",
    version="1.0.0",
    docs_url="/docs",
    redoc_url="/redoc",
)

# CORS configuration
allowed_origins = os.getenv("ALLOWED_ORIGINS", "*").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=allowed_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# =============================================================================
# Models
# =============================================================================


class HealthResponse(BaseModel):
    """Health check response model."""

    status: str
    timestamp: str
    environment: str


class HelloResponse(BaseModel):
    """Hello endpoint response model."""

    message: str
    timestamp: str


class Item(BaseModel):
    """Item model for example CRUD operations."""

    id: int
    name: str
    description: Optional[str] = None
    price: float
    in_stock: bool = True


# =============================================================================
# In-memory data store (replace with database in production)
# =============================================================================

items_db: List[Item] = [
    Item(id=1, name="Laptop", description="High-performance laptop", price=999.99, in_stock=True),
    Item(id=2, name="Mouse", description="Wireless mouse", price=29.99, in_stock=True),
    Item(id=3, name="Keyboard", description="Mechanical keyboard", price=89.99, in_stock=False),
]

# =============================================================================
# Endpoints
# =============================================================================


@app.get("/health", response_model=HealthResponse)
async def health_check():
    """
    Health check endpoint for Docker health checks and monitoring.

    Returns:
        HealthResponse: Current health status
    """
    return HealthResponse(
        status="healthy",
        timestamp=datetime.utcnow().isoformat(),
        environment=os.getenv("ENVIRONMENT", "unknown"),
    )


@app.get("/api/v1/hello", response_model=HelloResponse)
async def hello():
    """
    Simple hello world endpoint.

    Returns:
        HelloResponse: Greeting message
    """
    logger.info("Hello endpoint accessed")
    return HelloResponse(
        message=f"Hello from {os.getenv('APP_NAME', 'FastAPI')}!",
        timestamp=datetime.utcnow().isoformat(),
    )


@app.get("/api/v1/items", response_model=List[Item])
async def list_items(in_stock: Optional[bool] = None):
    """
    List all items or filter by stock status.

    Args:
        in_stock: Optional filter for stock status

    Returns:
        List[Item]: List of items
    """
    logger.info(f"Listing items (in_stock={in_stock})")

    if in_stock is not None:
        return [item for item in items_db if item.in_stock == in_stock]

    return items_db


@app.get("/api/v1/items/{item_id}", response_model=Item)
async def get_item(item_id: int):
    """
    Get a specific item by ID.

    Args:
        item_id: Item ID

    Returns:
        Item: Item details

    Raises:
        HTTPException: If item not found
    """
    logger.info(f"Getting item {item_id}")

    for item in items_db:
        if item.id == item_id:
            return item

    logger.warning(f"Item {item_id} not found")
    raise HTTPException(status_code=404, detail=f"Item {item_id} not found")


@app.post("/api/v1/items", response_model=Item, status_code=201)
async def create_item(item: Item):
    """
    Create a new item.

    Args:
        item: Item to create

    Returns:
        Item: Created item

    Raises:
        HTTPException: If item ID already exists
    """
    logger.info(f"Creating item {item.id}")

    # Check if item ID already exists
    if any(existing_item.id == item.id for existing_item in items_db):
        logger.warning(f"Item {item.id} already exists")
        raise HTTPException(status_code=400, detail=f"Item {item.id} already exists")

    items_db.append(item)
    logger.info(f"Item {item.id} created successfully")
    return item


@app.put("/api/v1/items/{item_id}", response_model=Item)
async def update_item(item_id: int, updated_item: Item):
    """
    Update an existing item.

    Args:
        item_id: Item ID to update
        updated_item: Updated item data

    Returns:
        Item: Updated item

    Raises:
        HTTPException: If item not found
    """
    logger.info(f"Updating item {item_id}")

    for i, item in enumerate(items_db):
        if item.id == item_id:
            items_db[i] = updated_item
            logger.info(f"Item {item_id} updated successfully")
            return updated_item

    logger.warning(f"Item {item_id} not found")
    raise HTTPException(status_code=404, detail=f"Item {item_id} not found")


@app.delete("/api/v1/items/{item_id}", status_code=204)
async def delete_item(item_id: int):
    """
    Delete an item.

    Args:
        item_id: Item ID to delete

    Raises:
        HTTPException: If item not found
    """
    logger.info(f"Deleting item {item_id}")

    for i, item in enumerate(items_db):
        if item.id == item_id:
            items_db.pop(i)
            logger.info(f"Item {item_id} deleted successfully")
            return

    logger.warning(f"Item {item_id} not found")
    raise HTTPException(status_code=404, detail=f"Item {item_id} not found")


# =============================================================================
# Startup/Shutdown Events
# =============================================================================


@app.on_event("startup")
async def startup_event():
    """
    Application startup event handler.
    Initialize resources, connections, etc.
    """
    logger.info("=" * 80)
    logger.info(f"Starting {os.getenv('APP_NAME', 'FastAPI')} API")
    logger.info(f"Environment: {os.getenv('ENVIRONMENT', 'unknown')}")
    logger.info(f"Log Level: {os.getenv('LOG_LEVEL', 'INFO')}")
    logger.info("=" * 80)


@app.on_event("shutdown")
async def shutdown_event():
    """
    Application shutdown event handler.
    Clean up resources, close connections, etc.
    """
    logger.info("=" * 80)
    logger.info(f"Shutting down {os.getenv('APP_NAME', 'FastAPI')} API")
    logger.info("=" * 80)


# =============================================================================
# Main
# =============================================================================

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host="0.0.0.0",
        port=int(os.getenv("PORT", 8000)),
        log_level=os.getenv("LOG_LEVEL", "info").lower(),
    )
