-- In order to get the insights on each customer, we start by creating the base dataset joining all relevant tables => base_dataset
DROP TABLE IF EXISTS combined_dataset;
CREATE TEMP TABLE combined_dataset AS
SELECT
  rental.customer_id,
  rental.rental_date,
  inventory.film_id,
  film.title,
  category.name as category_name
FROM dvd_rentals.rental 
INNER JOIN dvd_rentals.inventory 
ON rental.inventory_id = inventory.inventory_id
INNER JOIN dvd_rentals.film 
ON inventory.film_id = film.film_id
INNER JOIN dvd_rentals.film_category
ON film.film_id = film_category.film_id
INNER JOIN dvd_rentals.category
ON film_category.category_id = category.category_id;

-- Then from the base_dataset we get the total number of movies rented by a customer in each catgory
DROP TABLE IF EXISTS customer_category_counts;
CREATE TEMP TABLE customer_category_counts AS 
SELECT
  customer_id,
  category_name,
  COUNT(film_id) as category_count,
  MAX(rental_date) as latest_rental_date
FROM combined_dataset
GROUP BY 1,2;

-- And for the second category insight we need the comparison of a customer's current category with the overall watching history, we get the total number of rentals by a customer
DROP TABLE IF EXISTS customer_total;
CREATE TEMP TABLE customer_total AS
SELECT
  customer_id,
  SUM(category_count) as total_customer_rental
FROM customer_category_counts
GROUP BY 1;

-- For the first category, we need the comparison of the total rentals in that category with the overall category average
DROP TABLE IF EXISTS avg_category_counts;
CREATE TEMP TABLE avg_category_counts AS
SELECT
  category_name,
  FLOOR(AVG(category_count)) as avg_category_rental
FROM customer_category_counts
GROUP BY 1;

-- For each customer, we get the top 2 categories by ranking the categories based on the number of movies rented in each category
DROP TABLE IF EXISTS top_2_categories;
CREATE TEMP TABLE top_2_categories AS
WITH customer_category_rank AS (
SELECT
  customer_id,
  category_name,
  category_count,
  DENSE_RANK() OVER (PARTITION BY customer_id ORDER BY category_count DESC, latest_rental_date DESC, category_name) AS category_rank
FROM customer_category_counts)
SELECT * FROM customer_category_rank WHERE category_rank <=2;

-- For category 1 we need the percentile of the top category for each customer, hence we use the PERCENT_RANK() function to get this
DROP TABLE IF EXISTS customer_percentile_rank;
CREATE TEMP TABLE customer_percentile_rank AS
WITH base_percentile AS (
SELECT
  customer_id,
  category_name,
  PERCENT_RANK() OVER (PARTITION BY category_name ORDER BY category_count DESC) as customer_category_percentile
FROM customer_category_counts)
SELECT
  customer_id,
  category_name,
  CASE
  WHEN ROUND(100 * customer_category_percentile) = 0 THEN 1
  ELSE ROUND(100 * customer_category_percentile)
  END AS updated_customer_percentile
FROM base_percentile;


-- Finally we join the top_category, avg and percentile to get the insights for the first category of each customer
DROP TABLE IF EXISTS top_category_insights;
CREATE TEMP TABLE top_category_insights AS
SELECT
  t1.customer_id,
  t1.category_name,
  t1.category_count,
  t1.category_count - t3.avg_category_rental AS average_comparison,
  t2.updated_customer_percentile
FROM
  top_2_categories t1 
  LEFT JOIN customer_percentile_rank t2 ON t1.customer_id = t2.customer_id AND t1.category_name = t2.category_name
  LEFT JOIN avg_category_counts t3 ON t1.category_name = t3.category_name
  WHERE category_rank = 1;
  
-- Similarly we join the top_catgory table and the total customer counts table to get the insights of second category
DROP TABLE IF EXISTS second_category_insights;
CREATE TEMP TABLE second_category_insights AS
SELECT
  t1.customer_id,
  t1.category_name,
  t1.category_count,
  ROUND(100 * t1.category_count / t2.total_customer_rental :: NUMERIC) as category_percentage
FROM
  top_2_categories t1 
  LEFT JOIN customer_total t2 ON t1.customer_id = t2.customer_id 
  WHERE category_rank = 2;

-- To further compute the reommendations of movies to the customer in top 2 categories,
-- we first find out the movies rented by each customer
--   customer_id, film_id

DROP TABLE IF EXISTS customer_watched;
CREATE TEMP TABLE customer_watched AS 
SELECT DISTINCT --Considering that one customer can rent the same movie more than once
  customer_id,
  film_id
FROM combined_dataset;

-- We then find out the total number of rentals against each movie so that we can recommend top 3 by most rented movies to the customer which is not part of their viewing history
DROP TABLE IF EXISTS film_total_rentals;
CREATE TEMP TABLE film_total_rentals AS
SELECT DISTINCT -- One film can be rented more than once
  film_id,
  title,
  category_name,
  COUNT(*) OVER(PARTITION BY film_id) as total_film_rentals
FROM combined_dataset;

-- We then use the top 2 categories table and the film_total_rentals to get the top 3 movies based on the rental counts
-- In order to filter out the movies that a customer has already watched, we can use the ANTI JOIN here,
DROP TABLE IF EXISTS movie_recommendation;
CREATE TEMP TABLE movie_recommendation AS
WITH reco_table AS (
SELECT
  top_2_categories.customer_id,
  top_2_categories.category_name,
  top_2_categories.category_count,
  top_2_categories.category_rank,
  film_total_rentals.film_id,
  film_total_rentals.title,
  DENSE_RANK() OVER (PARTITION BY top_2_categories.customer_id, top_2_categories.category_name ORDER BY film_total_rentals.total_film_rentals DESC, film_total_rentals.title) as movie_reco_rank
FROM top_2_categories
INNER JOIN film_total_rentals
ON top_2_categories.category_name = film_total_rentals.category_name
WHERE NOT EXISTS (
  SELECT 1
  FROM customer_watched
  WHERE customer_watched.customer_id = top_2_categories.customer_id
  AND customer_watched.film_id = film_total_rentals.film_id))
SELECT * FROM reco_table WHERE movie_reco_rank <=3;

