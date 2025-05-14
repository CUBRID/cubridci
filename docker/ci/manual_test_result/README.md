The ip address of the qahome cubrid server is not included in the /src/manual_test_result.java file.
Need to modify the ip address in the /src/manual_test_result.java file and build jar file with below command.

- javac -d bin src/manual_test_result.java
- jar cfm ../manual_test_result.jar manifest.txt -C bin .
