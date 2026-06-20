import json
import logging
import requests
import streamlit as st
import numpy as np
from PIL import Image
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError
import boto3
from scipy.spatial import distance
from components.Parameter_store import S3_BUCKET_NAME

answer = None
show_prompt = None
prompt = None

bedrock_client = boto3.client("bedrock-runtime")
dynamodb = boto3.resource("dynamodb")

# Safe initialization of DynamoDB tables
try:
    assignments_table = dynamodb.Table("assignments")
    answers_table = dynamodb.Table("answers")
except Exception as e:
    st.error(f"❌ DynamoDB initialization failed: {e}")
    assignments_table, answers_table = None, None

user_name = "CloudAge-User"


# Retrieve records from assignments table
def get_assignments_from_dynamodb():
    if not assignments_table:
        return []
    try:
        response = assignments_table.scan()
        return response.get("Items", [])
    except ClientError as e:
        logging.error(f"DynamoDB error (assignments): {e}")
        return []


# Download an image from S3
def download_image(image_name, file_name):
    s3 = boto3.client("s3")
    try:
        s3.download_file(S3_BUCKET_NAME, image_name, file_name)
        return True
    except ClientError as e:
        logging.error(e)
        return False


# Get a specific record from answers table
def get_answer_record_from_dynamodb(student_id, assignment_id, question_id):
    if not answers_table:
        return None
    try:
        response = answers_table.get_item(
            Key={
                "student_id": student_id,
                "assignment_question_id": f"{assignment_id}_{question_id}",
            }
        )
        return response.get("Item")  # safe access
    except ClientError as e:
        logging.error(f"DynamoDB error (get_item): {e}")
        return None


# Get embeddings using Bedrock
def get_text_embed(payload):
    input_body = {"inputText": payload}
    api_response = bedrock_client.invoke_model(
        body=json.dumps(input_body),
        modelId="mistral.mistral-7b-instruct-v0:2",
        accept="application/json",
        contentType="application/json",
    )
    embedding_response = json.loads(api_response.get("body").read().decode("utf-8"))
    return list(embedding_response["embedding"])


# Query top scores for a question
def get_high_score_answer_records_from_dynamodb(assignment_id, question_id):
    if not answers_table:
        return []
    try:
        response = answers_table.query(
            IndexName="assignment_question_id-index",
            ProjectionExpression="student_id, score",
            KeyConditionExpression=Key("assignment_question_id").eq(
                f"{assignment_id}_{question_id}"
            ),
            ScanIndexForward=False,
            Limit=5,
        )
        return response.get("Items", [])
    except ClientError as e:
        logging.error(f"DynamoDB error (query): {e}")
        return []


# Generate sentence improvements
def generate_suggestions_sentence_improvements(text):
    model_id = "mistral.mistral-7b-instruct-v0:2"
    input_text = f"""{text}\nImprove the text above in a way that maintains its original meaning but uses different words and sentence structures. Keep your response in 1 sentence."""
    body = json.dumps(
        {
            "prompt": input_text,
            "max_tokens": 400,
            "temperature": 0,
            "top_p": 0.7,
            "top_k": 50,
        }
    )
    response = bedrock_client.invoke_model(body=body, modelId=model_id)
    response_body = json.loads(response.get("body").read())
    outputs = response_body.get("outputs", [])
    return "\n".join([output["text"] for output in outputs])


# Generate word-level improvements
def generate_suggestions_word_improvements(text):
    model_id = "mistral.mistral-7b-instruct-v0:2"
    input_text = f"""{text}\nReview the text above and correct any grammar errors. Keep your response in 1 sentence."""
    body = json.dumps(
        {
            "prompt": input_text,
            "max_tokens": 400,
            "temperature": 0,
            "top_p": 0.7,
            "top_k": 50,
        }
    )
    response = bedrock_client.invoke_model(body=body, modelId=model_id)
    response_body = json.loads(response.get("body").read())
    outputs = response_body.get("outputs", [])
    return "\n".join([output["text"] for output in outputs])


# ---------------- Streamlit Page ----------------
st.set_page_config(page_title="Answer Questions", page_icon=":question:", layout="wide")
st.markdown("# Answer Questions")
st.sidebar.header("Answer Questions")

# Load assignments
assignment_records = get_assignments_from_dynamodb()
assignment_ids = [record["assignment_id"] for record in assignment_records]
assignment_ids.insert(0, "<Select>")

assignment_id_selection = st.sidebar.selectbox("Select an assignment", assignment_ids)
assignment_selection = None

if assignment_id_selection and assignment_id_selection != "<Select>":
    for assignment_record in assignment_records:
        if assignment_record["assignment_id"] == assignment_id_selection:
            assignment_selection = assignment_record

if assignment_selection:
    image_name = assignment_selection["s3_image_name"]
    file_name = "temp-answer.png"
    if download_image(image_name, file_name):
        st.image(Image.open(file_name), width=128)

    st.write(assignment_selection["prompt"])
    question_answers = json.loads(assignment_selection["question_answers"])
    questions = [qa["Question"] for qa in question_answers]

    generate_question_selection = st.selectbox("Select a question", questions)
    answer = st.text_input("Please enter your answer!", key="prompt")

    correct_answer, question_id = None, None
    for qa in question_answers:
        if qa["Question"] == generate_question_selection:
            correct_answer = qa["Answer"]
            question_id = qa["Id"]
            break

    if answer and correct_answer:
        st.write("Your guess: ", answer)
        v1 = np.squeeze(np.array(get_text_embed(correct_answer)))
        v2 = np.squeeze(np.array(get_text_embed(answer)))
        dist = distance.cosine(v1, v2)
        score = int(100 - dist * 100)
        st.write(f"Your answer has a score of {score}")
        st.markdown("------------")

        db_record = get_answer_record_from_dynamodb(
            user_name, assignment_id_selection, question_id
        )
        if db_record:
            if db_record["score"] < score:
                db_record["score"] = score
                db_record["answer"] = answer
                answers_table.put_item(Item=db_record)
                st.write(f"✅ Updated: Your new score is {score}, answer: '{answer}'.")
        else:
            db_record = {
                "student_id": user_name,
                "assignment_question_id": f"{assignment_id_selection}_{question_id}",
                "answer": answer,
                "score": score,
            }
            if answers_table:
                answers_table.put_item(Item=db_record)
                st.write(f"✅ Saved: Your score is {score}, answer: '{answer}'.")

        high_score_records = get_high_score_answer_records_from_dynamodb(
            assignment_id_selection, question_id
        )
        st.write("🏆 Top Three High Scores:")
        for record in high_score_records:
            st.write(f"Student ID: {record['student_id']} - Score: {record['score']}")

        st.markdown("------------")
        st.markdown("Suggested corrections: ")
        st.write(generate_suggestions_word_improvements(answer))

        st.markdown("Suggested sentences: ")
        st.write(generate_suggestions_sentence_improvements(answer))

        if st.button("Show the correct answer"):
            st.write("Answer: ", correct_answer)

# Hide Streamlit branding
hide_streamlit_style = """
    <style>
        #MainMenu {visibility: hidden;}
        footer{ visibility: hidden;}
    </style>
"""
st.markdown(hide_streamlit_style, unsafe_allow_html=True)