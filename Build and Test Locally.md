# Build the Docker image
docker build -t my-html-app .

# Test locally
docker run -d -p 8080:80 --name test-app my-html-app

# Visit http://localhost:8080 to see your app
# Stop the test container
docker stop test-app
docker rm test-app